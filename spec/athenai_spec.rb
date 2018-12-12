module Athenai
  describe SaveHistory do
    subject :handler do
      described_class.new(
        athena_client: athena_client,
        s3_client: s3_client,
        history_base_uri: 's3://athena-query-history/some/prefix/',
        state_uri: state_uri,
        batch_size: 100,
        logger: logger,
      )
    end

    let :athena_client do
      Aws::Athena::Client.new(stub_responses: true).tap do |ac|
        responses = [
          ac.stub_data(:list_query_executions, query_execution_ids: query_execution_ids.take((query_execution_ids.size * 0.6).to_i)),
          ac.stub_data(:list_query_executions, query_execution_ids: query_execution_ids.drop((query_execution_ids.size * 0.6).to_i)),
        ]
        allow(ac).to receive(:list_query_executions).and_return(responses)
        allow(ac).to receive(:batch_get_query_execution) do |parameters|
          query_executions = parameters[:query_execution_ids].map do |id|
            {
              query_execution_id: id,
              status: {
                submission_date_time: Time.utc(2018, 12, 11, 10, 9, 8),
                completion_date_time: Time.utc(2018, 12, 11, 10, 9, 8),
              },
            }
          end
          ac.stub_data(:batch_get_query_execution, query_executions: query_executions)
        end
      end
    end

    let :s3_client do
      Aws::S3::Client.new(stub_responses: true).tap do |sc|
        allow(sc).to receive(:put_object) do |parameters|
          if parameters[:key].start_with?('some/prefix/')
            zio = Zlib::GzipReader.new(StringIO.new(parameters[:body]))
            zio.each_line do |line|
              saved_executions << JSON.load(line)
            end
            zio.close
          end
          sc.stub_data(:put_object)
        end
        allow(sc).to receive(:get_object) do |parameters|
          if !state_uri.nil? && !state_contents.nil? && state_uri.end_with?(parameters[:key])
            sc.stub_data(:get_object, body: StringIO.new(JSON.dump(state_contents)))
          else
            raise Aws::S3::Errors::NoSuchKey.new(nil, nil)
          end
        end
      end
    end

    let :saved_executions do
      []
    end

    let :query_execution_ids do
      Array.new(11) { |i| format('q%02x', i) }
    end

    let :state_uri do
      nil
    end

    let :state_contents do
      nil
    end

    let :logger do
      instance_double(Logger, debug: nil, info: nil, warn: nil)
    end

    describe '.handle' do
      before do
        allow(logger).to receive(:level=)
        allow(Aws::Athena::Client).to receive(:new).and_return(athena_client)
        allow(Aws::S3::Client).to receive(:new).and_return(s3_client)
        allow(Logger).to receive(:new).and_return(logger)
      end

      before do
        ENV['HISTORY_BASE_URI'] = 's3://history/base/uri'
        ENV['STATE_URI'] = 's3://state/uri.json'
      end

      after do
        ENV.delete('HISTORY_BASE_URI')
        ENV.delete('STATE_URI')
      end

      it 'initializes the handler with its dependencies and calls #save_history' do
        described_class.handler(event: nil, context: nil)
        expect(athena_client).to have_received(:list_query_executions)
      end

      it 'returns whatever #save_history returns' do
        expect(described_class.handler(event: nil, context: nil)).to eq('q00')
      end

      it 'picks up the history URI from the environment' do
        described_class.handler(event: nil, context: nil)
        expect(s3_client).to have_received(:put_object).with(hash_including(bucket: 'history', key: including('base/uri/')))
      end

      it 'picks up the state URI from the environment' do
        described_class.handler(event: nil, context: nil)
        expect(s3_client).to have_received(:put_object).with(hash_including(bucket: 'state', key: including('uri.json')))
      end
    end

    describe '#save_history' do
      it 'lists the query executions' do
        handler.save_history
        expect(athena_client).to have_received(:list_query_executions)
      end

      it 'looks up the query executions' do
        handler.save_history
        expect(athena_client).to have_received(:batch_get_query_execution).with(query_execution_ids: query_execution_ids)
      end

      it 'logs when it loads query execution metadata' do
        handler.save_history
        expect(logger).to have_received(:debug).with('Loading query execution metadata for 11 query executions')
      end

      it 'logs the submission date time of the last query execution of the batch' do
        handler.save_history
        expect(logger).to have_received(:debug).with('Last submission time of the batch was 2018-12-11 10:09:08 UTC')
      end

      it 'stores the query execution metadata in a key that contains the region, submission date time, and ID of the first processed query execution ID' do
        handler.save_history
        expect(s3_client).to have_received(:put_object).with(hash_including(key: 'some/prefix/us-stubbed-1/2018/12/11/10/q00.json.gz'))
      end

      it 'stores the query execution metadata on S3 in the specified bucket and prefix' do
        handler.save_history
        expect(s3_client).to have_received(:put_object).with(hash_including(bucket: 'athena-query-history', key: start_with('some/prefix/')))
      end

      it 'logs when it stores query execution metadata' do
        handler.save_history
        expect(logger).to have_received(:debug).with('Saving execution metadata for 11 queries to s3://athena-query-history/some/prefix/us-stubbed-1/2018/12/11/10/q00.json.gz')
        expect(logger).to have_received(:info).with('Saved execution metadata for 11 queries')
      end

      it 'stores the query execution metadata as JSON streams' do
        handler.save_history
        expect(saved_executions).to contain_exactly(
          hash_including('query_execution_id' => 'q00'),
          hash_including('query_execution_id' => 'q01'),
          hash_including('query_execution_id' => 'q02'),
          hash_including('query_execution_id' => 'q03'),
          hash_including('query_execution_id' => 'q04'),
          hash_including('query_execution_id' => 'q05'),
          hash_including('query_execution_id' => 'q06'),
          hash_including('query_execution_id' => 'q07'),
          hash_including('query_execution_id' => 'q08'),
          hash_including('query_execution_id' => 'q09'),
          hash_including('query_execution_id' => 'q0a'),
        )
      end

      it 'formats the timestamps in the query execution metadata in the UTC time zone and in a format compatible with Hive' do
        handler.save_history
        expect(saved_executions.first.dig('status', 'submission_date_time')).to eq('2018-12-11 10:09:08.000')
        expect(saved_executions.first.dig('status', 'completion_date_time')).to eq('2018-12-11 10:09:08.000')
      end

      it 'adds the region to the query execution metadata' do
        handler.save_history
        expect(saved_executions.first).to include('region' => 'us-stubbed-1')
      end

      it 'logs when it is done' do
        handler.save_history
        expect(logger).to have_received(:info).with('Done')
      end

      it 'returns the first processed query execution ID' do
        expect(handler.save_history).to eq('q00')
      end

      context 'when there are more than 50 query executions' do
        let :query_execution_ids do
          Array.new(121) { |i| format('q%02x', i) }
        end

        it 'looks up the query executions 50 at a time' do
          handler.save_history
          expect(athena_client).to have_received(:batch_get_query_execution).with(query_execution_ids: query_execution_ids.take(50))
          expect(athena_client).to have_received(:batch_get_query_execution).with(query_execution_ids: query_execution_ids.drop(50).take(50))
          expect(athena_client).to have_received(:batch_get_query_execution).with(query_execution_ids: query_execution_ids.drop(100))
        end

        context 'and the number is evenly divisible by 50' do
          let :query_execution_ids do
            Array.new(100) { |i| format('q%02x', i) }
          end

          it 'does not make an empty lookup call' do
            handler.save_history
            expect(athena_client).to_not have_received(:batch_get_query_execution).with(query_execution_ids: [])
          end
        end
      end

      context 'when there are more query executions than the batch size' do
        let :query_execution_ids do
          Array.new(211) { |i| format('q%02x', i) }
        end

        it 'stores the query executions one batch at a time at a time' do
          handler.save_history
          expect(s3_client).to have_received(:put_object).with(hash_including(key: 'some/prefix/us-stubbed-1/2018/12/11/10/q00.json.gz'))
          expect(s3_client).to have_received(:put_object).with(hash_including(key: 'some/prefix/us-stubbed-1/2018/12/11/10/q64.json.gz'))
          expect(s3_client).to have_received(:put_object).with(hash_including(key: 'some/prefix/us-stubbed-1/2018/12/11/10/qc8.json.gz'))
          expect(saved_executions.size).to eq(211)
        end
      end

      context 'when there are no query executions' do
        let :query_execution_ids do
          []
        end

        it 'does not store any data on S3' do
          handler.save_history
          expect(s3_client).to_not have_received(:put_object)
        end

        it 'returns nil' do
          expect(handler.save_history).to be_nil
        end
      end

      context 'when given a state key' do
        let :state_uri do
          's3://state/some/other/prefix/key.json.gz'
        end

        let :state_contents do
          {'last_query_execution_id' => 'q03'}
        end

        it 'attempts to load the last query execution ID from the given key in the history bucket' do
          handler.save_history
          expect(saved_executions.size).to eq(3)
        end

        it 'loads query execution metadata until it finds the last query execution ID given by the state' do
          handler.save_history
          expect(saved_executions).to contain_exactly(
            hash_including('query_execution_id' => 'q00'),
            hash_including('query_execution_id' => 'q01'),
            hash_including('query_execution_id' => 'q02'),
          )
        end

        it 'logs when it finds the last query execution ID' do
          handler.save_history
          expect(logger).to have_received(:info).with('Found the last previously processed query execution ID')
        end

        it 'stores the first query execution ID in an object at the specified URI' do
          handler.save_history
          expect(s3_client).to have_received(:put_object).with(bucket: 'state', key: 'some/other/prefix/key.json.gz', body: JSON.dump('last_query_execution_id' => 'q00'))
        end

        it 'logs when it loads the state' do
          handler.save_history
          expect(logger).to have_received(:debug).with('Loading state from s3://state/some/other/prefix/key.json.gz')
          expect(logger).to have_received(:info).with('Loaded last query execution ID: "q03"')
        end

        it 'logs when it stores the state' do
          handler.save_history
          expect(logger).to have_received(:debug).with('Saving state to s3://state/some/other/prefix/key.json.gz')
          expect(logger).to have_received(:info).with('Saved first processed query execution ID: "q00"')
        end

        context 'when the state key does not exist' do
          let :state_contents do
            nil
          end

          it 'acts as if the last query execution ID was nil' do
            handler.save_history
            expect(saved_executions.size).to eq(11)
          end

          it 'still stores the first query execution ID' do
            handler.save_history
            expect(s3_client).to have_received(:put_object).with(bucket: 'state', key: 'some/other/prefix/key.json.gz', body: JSON.dump('last_query_execution_id' => 'q00'))
          end

          it 'logs that it did not find any state' do
            handler.save_history
            expect(logger).to have_received(:warn).with('No state found at s3://state/some/other/prefix/key.json.gz')
          end
        end

        context 'and the state contains other information than the last query execution ID' do
          let :state_contents do
            {'last_query_execution_id' => 'q03', 'something' => 'else'}
          end

          it 'retains that data when it saves the state back' do
            handler.save_history
            expect(s3_client).to have_received(:put_object).with(bucket: 'state', key: 'some/other/prefix/key.json.gz', body: JSON.dump('last_query_execution_id' => 'q00', 'something' => 'else'))
          end
        end
      end
    end
  end
end