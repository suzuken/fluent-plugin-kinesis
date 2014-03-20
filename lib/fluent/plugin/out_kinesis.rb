module Fluent
    class KinesisOutput < Fluent::BufferedOutput
        Fluent::Plugin.register_output('kinesis',self)

        def initialize
            super
            require 'aws-sdk'
            require 'base64'
            require 'yajl'
            require 'logger'
        end

        config_param :aws_key_id,   :string, :default => nil
        config_param :aws_sec_key,  :string, :default => nil
        config_param :region,       :string, :default => nil

        config_param :stream_name,            :string, :default => nil
        config_param :partition_key,          :string, :default => nil
        config_param :partition_key_proc,     :string, :default => nil
        config_param :explicit_hash_key,      :string, :default => nil
        config_param :explicit_hash_key_proc, :string, :default => nil

        config_param :sequence_number_for_ordering, :string, :default => nil

        config_param :include_tag,  :bool, :default => true
        config_param :include_time, :bool, :default => true
        config_param :debug,        :bool, :default => false

        def configure(conf)
            super

            [:aws_key_id, :aws_sec_key, :region, :stream_name].each do |name|
                unless self.instance_variable_get("@#{name}")
                    raise ConfigError, "'#{name}' is required"
                end
            end

            unless @partition_key or @partition_key_proc
                raise ConfigError, "'partition_key' or 'partition_key_proc' is required"
            end

            if @partition_key_proc
                @partition_key_proc = eval(@partition_key_proc)
            end

            if @explicit_hash_key_proc
                @explicit_hash_key_proc = eval(@explicit_hash_key_proc)
            end
        end

        def start
            super
            configure_aws
            @client = AWS.kinesis.client
            @client.describe_stream(:stream_name => @stream_name)
        end

        def shutdown
            super
        end

        def format(tag, time, record)
            record['__tag'] = tag if @include_tag
            record['__time'] = time if @include_time

            # XXX: The maximum size of the data blob is 50 kilobytes
            # http://docs.aws.amazon.com/kinesis/latest/APIReference/API_PutRecord.html
            data = {
                :stream_name => @stream_name,
                :data => encode64(record.to_json),
                :partition_key => get_key(:partition_key,record)
            }

            if @explicit_hash_key or @explicit_hash_key_proc
                data[:explicit_hash_key] = get_key(:explicit_hash_key,record)
            end

            if @sequence_number_for_ordering
                data[:sequence_number_for_ordering] = @sequence_number_for_ordering
            end

            pack_data(data)
        end

        def write(chunk)
            buf = chunk.read

            while (data = unpack_data(buf))
                AWS.kinesis.client.put_record(data)
            end
        end

        private
        def configure_aws
            options = {
                :access_key_id => @aws_key_id,
                :secret_access_key => @aws_sec_key,
                :region => @region
            }

            if @debug
                options.update(
                    :logger => Logger.new($log.out),
                    :log_level => :debug
                )
                # XXX: Add the following options, if necessary
                # :http_wire_trace => true
            end

            AWS.config(options)
        end

        def get_key(name, record)
            key = self.instance_variable_get("@#{name}")
            key_proc = self.instance_variable_get("@#{name}_proc")

            value = key ? record[key] : record

            if key_proc
                value = key_proc.arity.zero? ? key_proc.call : key_proc.call(value)
            end

            value.to_s
        end

        def pack_data(data)
            data = data.to_msgpack(data)
            force_encoding(data,'ascii-8bit')
            [data.length].pack('L') + data
        end

        def unpack_data(buf)
            return nil if buf.empty?

            force_encoding(buf,'ascii-8bit')
            length = buf.slice!(0,4).unpack('L').first
            data = buf.slice!(0,length)
            MessagePack.unpack(data)
        end

        def encode64(str)
            Base64.encode64(str).delete("\n")
        end

        def force_encoding(str, encoding)
            if str.respond_to?(:force_encoding)
                str.force_encoding(encoding)
            end
        end
    end
end
