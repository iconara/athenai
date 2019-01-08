require 'logger'
require 'time'
require 'zlib'
require 'stringio'
require 'aws-sdk-athena'
require 'aws-sdk-s3'

module Athenai
  class SaveHistory
    MAX_GET_QUERY_EXECUTION_BATCH_SIZE = 50

    def initialize(athena_client:, s3_client:, history_base_uri:, batch_size: 10_000, state_uri: nil, sleep_service: Kernel, logger: nil)
      unless history_base_uri
        raise ArgumentError, 'No history base URI specified'
      end
      @athena_client = athena_client
      @s3_client = s3_client
      @history_base_uri = history_base_uri
      @state_uri = state_uri
      @batch_size = batch_size
      @sleep_service = sleep_service
      @logger = logger
      @last_query_execution_id = nil
      @state_saved = false
    end

    def self.handler(event:, context:)
      athena_client = Aws::Athena::Client.new(region: ENV['AWS_REGION'])
      s3_client = Aws::S3::Client.new(region: ENV['AWS_REGION'])
      logger = Logger.new($stderr)
      logger.level = Logger::DEBUG
      handler = new(
        athena_client: athena_client,
        s3_client: s3_client,
        history_base_uri: ENV['HISTORY_BASE_URI'],
        state_uri: ENV['STATE_URI'],
        logger: logger,
      )
      handler.save_history
    end

    def save_history
      load_state
      ids = []
      query_executions = []
      first_query_execution_id = nil
      catch :done do
        each_query_execution_id do |query_execution_id|
          if query_execution_id == @last_query_execution_id
            @logger.info('Found the last previously processed query execution ID')
            throw :done
          else
            first_query_execution_id ||= query_execution_id
            ids << query_execution_id
            if ids.size == MAX_GET_QUERY_EXECUTION_BATCH_SIZE
              query_executions.concat(load_query_execution_metadata(ids))
              if query_executions.size >= @batch_size
                save_query_execution_metadata(query_executions)
                save_state(first_query_execution_id)
                query_executions = []
              end
              ids = []
            end
          end
        end
      end
      unless ids.empty?
        query_executions.concat(load_query_execution_metadata(ids))
      end
      unless query_executions.empty?
        save_query_execution_metadata(query_executions)
        save_state(first_query_execution_id)
      end
      @logger.info('Done')
      first_query_execution_id
    end

    private def split_s3_uri(uri)
      uri.scan(%r{\As3://([^/]+)/(.+)\z}).first
    end

    private def load_state
      if @state_uri
        begin
          @logger.debug(format('Loading state from %s', @state_uri))
          state_bucket, state_key = split_s3_uri(@state_uri)
          response = @s3_client.get_object(bucket: state_bucket, key: state_key)
          @state = JSON.load(response.body)
          @last_query_execution_id = @state['last_query_execution_id']
          @logger.info(format('Loaded last query execution ID: "%s"', @last_query_execution_id))
        rescue Aws::S3::Errors::NoSuchKey
          @state = {}
          @logger.warn(format('No state found at %s', @state_uri))
        end
      end
    end

    private def each_query_execution_id(&block)
      next_token = nil
      loop do
        response =  retry_throttling do
          @athena_client.list_query_executions(next_token: next_token)
        end
        response.query_execution_ids.each(&block)
        if (t = response.next_token)
          next_token = t
        else
          break
        end
      end
    end

    private def retry_throttling
      attempts = 0
      begin
        attempts += 1
        yield
      rescue Aws::Athena::Errors::ThrottlingException
        @sleep_service.sleep([2**(attempts - 1), 16].min)
        retry
      end
    end

    private def load_query_execution_metadata(query_execution_ids)
      @logger.debug(format('Loading query execution metadata for %d query executions', query_execution_ids.size))
      response = retry_throttling do
        @athena_client.batch_get_query_execution(query_execution_ids: query_execution_ids)
      end
      if (last = response.query_executions.last)
        time = last.status.submission_date_time.dup.utc
        @logger.debug(time.strftime('Last submission time of the batch was %F %T %Z'))
      end
      response.query_executions
    end

    private def create_metadata_log_contents(query_executions)
      region = @athena_client.config.region
      zio = Zlib::GzipWriter.new(StringIO.new)
      query_executions.each do |query_execution|
        h = query_execution.to_h
        s = h.dig(:status, :submission_date_time).dup.utc
        c = h.dig(:status, :completion_date_time).dup&.utc
        h = h.merge(
          region: region,
          status: h[:status].merge(
            submission_date_time: s.strftime('%F %T.%L'),
            completion_date_time: c&.strftime('%F %T.%L'),
          ),
        )
        zio.puts(JSON.dump(h))
      end
      zio.close.string
    end

    private def create_metadata_log_key(prefix, first_query_execution)
      key = prefix.dup
      key << '/' unless key.end_with?('/')
      key << @athena_client.config.region
      key << '/'
      key << first_query_execution.status.submission_date_time.strftime('%Y/%m/%d/%H/')
      key << first_query_execution.query_execution_id
      key << '.json.gz'
      key
    end

    private def save_state(first_query_execution_id)
      if @state_uri && !@state_saved
        @logger.debug(format('Saving state to %s', @state_uri))
        state_bucket, state_key = split_s3_uri(@state_uri)
        body = JSON.dump(@state.merge('last_query_execution_id' => first_query_execution_id))
        @s3_client.put_object(bucket: state_bucket, key: state_key, body: body)
        @logger.info(format('Saved first processed query execution ID: "%s"', first_query_execution_id))
        @state_saved = true
      end
    end

    private def save_query_execution_metadata(query_executions)
      first_query_execution = query_executions.first
      body = create_metadata_log_contents(query_executions)
      history_bucket, history_prefix = split_s3_uri(@history_base_uri)
      key = create_metadata_log_key(history_prefix, first_query_execution)
      @logger.debug(format('Saving execution metadata for %d queries to s3://%s/%s', query_executions.size, history_bucket, key))
      @s3_client.put_object(bucket: history_bucket, key: key, body: body)
      @logger.info(format('Saved execution metadata for %d queries', query_executions.size))
      first_query_execution
    end
  end
end
