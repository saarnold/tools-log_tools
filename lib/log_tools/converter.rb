require 'pocolog'
require 'utilrb/logger'
require 'orocos'

module Kernel
    # Like instace_eval but allows parameters to be passed.
    def instance_exec(*args, &block)
        mname = "__instance_exec_#{Thread.current.object_id.abs}_#{object_id.abs}"
        Object.class_eval{ define_method(mname, &block) }
        begin
            ret = send(mname, *args)
        ensure
            Object.class_eval{ undef_method(mname) } rescue nil
        end
        ret
    end
end

module LogTools
    extend Logger::Root('LogTools', Logger::INFO)

    class TypeConverter 
        attr_reader :time_from,:new_registry,:name
        SubConverter = Struct.new(:old_type_name,:new_type_name,:block) 

        def initialize(name,time_from,new_registry=Orocos.registry,&block)
            return time_from if time_from.is_a? TypeConverter

            #check parameter
            raise 'Parameter time_from must be of type Time' unless time_from.is_a? Time
            raise 'Parameter new_registry must be of type Typelib::Registry' unless new_registry.is_a? Typelib::Registry

            @name_hash = Hash.new
            @name = name
            @time_from = time_from
            @new_registry = new_registry
            instance_eval(&block)
        end

        def new_name_for type_name
            type_name = type_name.class.name unless type_name.is_a? String
            c = @name_hash[type_name]
            c.new_type_name if c
        end

        def new_sample_for type_name
            name = new_name_for type_name
            @new_registry.get(name).new
        end

        def old_type_names
            @name_hash.keys
        end

        def convert_field_from?(sample)
            @name_hash.each_key do |key|
                begin 
                    sample2 = sample.class.registry.get(key)
                    return true if sample.class.contains?(sample2) 
                rescue Typelib::NotFound => e
                end
            end
            false
        end

        def convert? type_name
            type_name = type_name.class.name unless type_name.is_a? String
            return @name_hash.has_key? type_name
        end

        def convert(dest,src,src_type_name,caller_obj)
            src_type_name = src.class.name unless src_type_name
            c = @name_hash[src_type_name]
            raise "Cannot convert #{src_type_name}!!!" unless c
            caller_obj.instance_exec(dest,src,&c.block)
        end

        def conversion(old_type_name,new_type_name=nil,&block) 
            new_type_name = old_type_name unless new_type_name
            raise 'Parameter old_type_name must be of type String' unless old_type_name.is_a? String
            raise 'Parameter new_type_name must be of type String' unless new_type_name.is_a? String

            begin 
                new_registry.get(new_type_name) #typelib is raising an error if not
            rescue Typelib::NotFound => e
                # try to solve the problem by loading a typekit
                if new_registry == Orocos.registry
                    Orocos.load_typekit_for new_type_name
                else
                    raise e
                end
            end
            @name_hash[old_type_name] = SubConverter.new(old_type_name,new_type_name,block)
        end
    end

    class Converter
        extend Logger::Hierarchy
        extend Logger::Forward

        class << self 
            attr_reader :converters
        end
        @converters = Array.new

        attr_accessor :pre_fix, :post_fix, :logger, :output_folder, :streams, :from, :to

        #method to register custom converters
        #it is allowed to use deep_cast insight the converter to convert subfields
        def self.register(*parameter,&block)
            @converters << TypeConverter.new(*parameter,&block)
            @converters.sort!{|a,b| a.time_from <=> b.time_from}
        end

        def initialize
            @converters = Converter.converters.clone
            @current_converter = nil
            @post_fix =""
            @pre_fix =""
            @from = nil
            @to = nil
            @streams = Array.new
            @output_folder = "updated"
        end

        def register(*parameter,&block)
            @converters << TypeConverter.new(*parameter,&block)
            @converters.sort!{|a,b| a.time_from <=> b.time_from}
        end

        #creates a file path for a new file based on the old file path
        def new_file_path(old_file_path)
            if File.directory?(output_folder)
                File.join(output_folder,pre_fix+File.basename(old_file_path,".log")+post_fix)
            else
                File.join(File.dirname(old_file_path),pre_fix+File.basename(old_file_path,".log")+post_fix)
            end
        end

        #converts logfiles to a new version 
        #if the last parameter is a Time object 
        #the logfiles are converted to a version which was valid at
        #given time. The current Orocos.registry must have 
        #the same type version !!!
        def convert(*logfiles)

            #create folder if given
            if output_folder && !File.directory?(output_folder)
                Dir.mkdir(output_folder)
            end

            logfiles.flatten!      

            #check last parameters
            final_registry = nil
            if logfiles.last.is_a? Typelib::Registry
                final_registry = logfiles.pop
            else
                final_registry = Orocos.registry
            end

            @current_registry = final_registry # this has to be removed later
            time_to=Time.now
            if logfiles.last.is_a? Time
                time_to = logfiles.pop
            end

            logfiles.each do |logfile|
                Converter.info "converting #{logfile}"

                file = Pocolog::Logfiles.open(logfile)
                output = Pocolog::Logfiles.create(new_file_path(logfile))
                time = Time.now
                file.streams.each do |stream|
                    if(streams && (stream.is_a?(Array) && !streams.include?(stream.name) || streams != stream.name))
                        #ignore all streams which are not listed if a filter is given
                        Converter.info "ignoring stream #{stream.name} (#{stream.size} samples)"
                        next
                    end

                    Converter.info " converting stream #{stream.name} (#{stream.size} samples)"
                    stream_output = nil
                    index = 1
                    last_ignore = nil
                    stream.samples.each do |lg,rt,sample|
                        ignore = (from && lg < from) || (to && lg > to)
                        if last_ignore != ignore
                            Converter.info "### ignoring samples enabled  ###" if ignore
                            Converter.info "### ignoring samples disabled ###" if !ignore
                            last_ignore = ignore
                        end

                        if (Time.now-time).to_f < 1
                            Converter.debug "    #{stream.name}.sample #{index}/#{stream.size}"
                        else
                            time = Time.now
                            Converter.info "    #{stream.name}.sample #{index}/#{stream.size}"
                        end
                        if !ignore
                            new_sample = convert_type(sample,lg,time_to,final_registry)
                            new_sample_class = new_sample.class
                            #use type_name of the old stream if we have for example a fixnum 
                            new_sample_class = stream.type_name unless new_sample_class.respond_to? :registry
                            stream_output ||= output.stream(stream.name,new_sample_class,true)
                            stream_output.write(lg,rt,new_sample)
                        end
                        index += 1
                    end
                    Converter.info "### ignoring samples disabled ###" if last_ignore
                    Converter.info "    done!"
                end
                output.close
            end
        end

        def clear
            @converters.clear
        end

        #convertes sample to a new type which was valid at time_to
        #the final_registry must have a compatible version!!!
        def convert_type(sample,time_from,time_to=Time.now,final_registry=Orocos.registry)
            raise 'No time periode is given!!!' unless time_from && time_to
            _converters = @converters.map{|c|(c.time_from>=time_from && c.time_from <= time_to) ? c : nil }
            _converters.compact!
            if !_converters.empty?
                _converters.each_with_index do |c,index|
                    @current_converter = c
                    #update current_registry

                    new_sample = nil
                    if @current_converter.convert?(sample)
                        Converter.debug "     Using Converter: #{c.name}" 
                        new_sample = @current_converter.new_sample_for sample
                    else
                        if(sample.is_a?(Fixnum)||sample.is_a?(Float))
                            return sample
                        end
                        begin
                            new_sample = @current_registry.get(sample.class.name).new
                        rescue Typelib::NotFound => e
                            #try to load typekit if @current_registry == Orocos.registry
                            if @current_registry == Orocos.registry
                                Orocos.load_typekit_for sample.class.name
                                new_sample = @current_registry.get(sample.class.name).new
                            else
                                raise e
                            end
                        end
                    end
                    deep_cast(new_sample,sample)
                    sample = new_sample
                end
            else
                #this can be removed later if typelib is supporting daisy chain 
                @current_registry = nil         # we have to convert it via deep_cast
            end

            #this is needed to be sure that the version is compatible to the
            #final registry
            if @current_registry != final_registry
                @current_converter = nil
                @current_registry = final_registry
                new_sample = @current_registry.get(sample.class.name).new
                deep_cast(new_sample,sample)
                sample = new_sample
            end
            sample
        end

        #copies a vector
        def copy_vector(to,from)
            if to.respond_to?(:data)
                from.data.to_a.each_with_index do |data,i|
                    to.data[i] = data 
                end
            else
                from.data.to_a.each_with_index do |data,i|
                    to[i] = data 
                end
            end
        end

        #converts src Typelib::Type int dest Typelib::Type
        #uses converters to convert fields and sub fields which have changed
        def deep_cast(dest,src,*excluded_fields)
            @@message = false if !defined? @@message

            excluded_fields.flatten!

            if !dest.is_a?(Typelib::Type) || !src.is_a?(Typelib::Type)
                raise "Cannot convert #{src.class.name} into #{dest.class.name}. "+
                    "Register a converter which does the conversion"
            end

            do_not_cast_self = excluded_fields.include?(:self) ? true : false
            excluded_fields.delete :self if do_not_cast_self

            src_type  = src.class
            dest_type = dest.class

            if @current_converter && @current_converter.convert?(src.class.name) && !do_not_cast_self
                Converter.debug "convert for #{dest_type}"
                @current_converter.convert(dest,src,nil,self)
            else
                if(dest_type.casts_to?(src_type) && !do_not_cast_self &&(!@current_converter||!@current_converter.convert_field_from?(src)))
                    Converter.debug "copy for #{dest_type}" #if @@message
                    Typelib.copy(dest, src)
                elsif src_type < Typelib::ContainerType
                    Converter.debug "deep cast for #{src_type}"
                    dest.clear
                    element_type = dest_type.deference
                    src.each do |src_element|
                        dst_element = element_type.new
                        if src_element.is_a? Typelib::Type
                            deep_cast(dst_element, src_element)
                        else
                            dst_element = src_element
                        end
                        dest.insert dst_element
                    end
                elsif src_type < Typelib::CompoundType
                    Converter.debug "deep cast2 for #{src_type}" if @@message

                    dest_fields = dest_type.get_fields.
                        map { |field_name, _| field_name }.
                        to_set

                    src_type.each_field do |field_name, src_field_type|
                        next if excluded_fields.include? field_name
                        next if !dest_fields.include?(field_name)

                        dest_field_type = dest_type[field_name]
                        src_value = src.raw_get_field(field_name)

                        if src_value.is_a? NilClass
                            Log.warn "field #{field_name} has an undefined value"
                            next
                        end
                        if src_value.is_a? Typelib::Type 
                            if @current_converter && @current_converter.convert?(src_field_type.name)
                                dest.raw_set_field(field_name,@current_converter.new_sample_for(src_field_type.name))
                            end
                            excluded_fields2 = excluded_fields.map{|field| field.match("#{field_name}\.(.*)");$1}.compact
                            deep_cast(dest.raw_get_field(field_name), src_value,excluded_fields2)
                        else
                            #check if the value has to be converted 
                            if(@current_converter && @current_converter.convert?(src_field_type.name))
                                Converter.debug "convert2 for #{src_field_type.name}" if @@message
                                #be carefull string, symbol etc are no reference  
                                dest_temp = @current_converter.new_sample_for src_field_type.name
                                dest_temp = @current_converter.convert(dest_temp,src.raw_get_field(field_name),src_field_type.name,self)
                                dest.raw_set_field(field_name,dest_temp)
                            else
                                dest.raw_set_field(field_name,src.raw_get_field(field_name))
                            end
                        end
                    end
                else
                    raise ArgumentError, "cannot deep cast #{src_type} into #{dest_type}"
                end
            end
            dest
        end
    end
end
