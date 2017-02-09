# encoding: utf-8
#
require "logstash/agent"
require_relative "../../support/helpers"
require_relative "../../support/matchers"
require_relative "../../support/mocks_classes"
require "spec_helper"

def mval(*path_elements)
  metric.get_shallow(*path_elements).value
end

describe LogStash::Agent do
  # by default no tests uses the auto reload logic
  let(:agent_settings) { mock_settings("config.reload.automatic" => false) }

  let(:pipeline_config) { mock_pipeline_config(:main, "input { generator {} } output { null {} }") }
  let(:update_pipeline_config) { mock_pipeline_config(:main, "input { generator { id => 'new' } } filter { mutate {} } output { null {} }") }
  let(:bad_update_pipeline_config) { mock_pipeline_config(:main, "hooo }") }

  let(:new_pipeline_config) { mock_pipeline_config(:new, "input { generator {} } output { null {} }") }
  let(:bad_pipeline_config) { mock_pipeline_config(:bad, "hooo }") }
  let(:second_bad_pipeline_config) { mock_pipeline_config(:second_bad, "hooo }") }

  let(:source_loader) do
    TestSourceLoader.new([])
  end

  subject { described_class.new(agent_settings, source_loader) }

  before :each do
    # until we decouple the webserver from the agent
    allow(subject).to receive(:start_webserver).and_return(false)
    allow(subject).to receive(:stop_webserver).and_return(false)
  end

  after :each do
    subject.shutdown
  end

  let(:metric) { subject.metric.collector.snapshot_metric.metric_store }

  context "when starting the agent" do
    it "initialize the instance reload metrics" do
      expect(mval(:stats, :reloads, :successes)).to eq(0)
      expect(mval(:stats, :reloads, :failures)).to eq(0)
    end
  end

  context "when we try to start one pipeline" do
    context "and it succeed" do
      let(:source_loader) do
        TestSourceLoader.new(pipeline_config)
      end

      let(:pipeline_name) { :main }

      it "doesnt changes the global successes" do
        expect { subject.converge_state_and_update }.not_to change { mval(:stats, :reloads, :successes) }
      end

      it "doesn't change the failures" do
        expect { subject.converge_state_and_update }.not_to change { mval(:stats, :reloads, :failures) }
      end

      it "sets the failures to 0" do
        subject.converge_state_and_update
        expect(mval(:stats, :pipelines, pipeline_name, :reloads, :failures)).to eq(0)
      end

      it "sets the successes to 0" do
        subject.converge_state_and_update
        expect(mval(:stats, :pipelines, pipeline_name, :reloads, :successes)).to eq(0)
      end

      it "sets the `last_error` to nil" do
        subject.converge_state_and_update
        expect(mval(:stats, :pipelines, pipeline_name, :reloads, :last_error)).to be_nil
      end

      it "sets the `last_failure_timestamp` to nil" do
        subject.converge_state_and_update
        expect(mval(:stats, :pipelines, :main, :reloads, :last_failure_timestamp)).to be_nil
      end

      it "sets the `last_success_timestamp` to nil" do
        subject.converge_state_and_update
        expect(mval(:stats, :pipelines, pipeline_name, :reloads, :last_success_timestamp)).to be_nil
      end
    end

    context "and it fails" do
      let(:source_loader) do
        TestSourceLoader.new(bad_pipeline_config)
      end

      let(:pipeline_name) { :bad }

      before do
        subject.converge_state_and_update
      end

      it "doesnt changes the global successes" do
        expect { subject.converge_state_and_update }.not_to change { mval(:stats, :reloads, :successes)}
      end

      it "doesn't change the failures" do
        expect { subject.converge_state_and_update }.to change { mval(:stats, :reloads, :failures) }.by(1)
      end

      it "increments the pipeline failures" do
        expect { subject.converge_state_and_update }.to change { mval(:stats, :pipelines, pipeline_name, :reloads, :failures) }.by(1)
      end

      it "sets the successes to 0" do
        subject.converge_state_and_update
        expect(mval(:stats, :pipelines, pipeline_name, :reloads, :successes)).to eq(0)
      end

      it "increase the global failures" do
        expect { subject.converge_state_and_update }.to change { mval(:stats, :reloads, :failures) }
      end

      it "records the `last_error`" do
        expect(mval(:stats, :pipelines, pipeline_name, :reloads, :last_error)).to_not be_nil
      end

      it "records the `message` and the `backtrace`" do
        expect(mval(:stats, :pipelines, pipeline_name, :reloads, :last_error)[:message]).to_not be_nil
        expect(mval(:stats, :pipelines, pipeline_name, :reloads, :last_error)[:backtrace]).to_not be_nil
      end

      it "records the time of the last failure" do
        expect(mval(:stats, :pipelines, pipeline_name, :reloads, :last_failure_timestamp)).to_not be_nil
      end

      it "initializes the `last_success_timestamp`" do
        expect(mval(:stats, :pipelines, pipeline_name, :reloads, :last_success_timestamp)).to be_nil
      end
    end

    context "when we try to reload a pipeline" do
      before do
        # Running Pipeline to -> reload pipeline
        expect(subject.converge_state_and_update.success?).to be_truthy
      end

      let(:pipeline_name) { :main }

      context "and it succeed" do
        let(:source_loader) do
          TestSequenceSourceLoader.new(pipeline_config, update_pipeline_config)
        end

        it "increments the global successes" do
          expect { subject.converge_state_and_update }.to change { mval(:stats, :reloads, :successes) }.by(1)
        end

        it "increment the pipeline successes" do
          expect{ subject.converge_state_and_update }.to change { mval(:stats, :pipelines, pipeline_name, :reloads, :successes) }.by(1)
        end

        it "record the `last_success_timestamp`" do
          expect(mval(:stats, :pipelines, pipeline_name, :reloads, :last_success_timestamp)).to be_nil
          subject.converge_state_and_update
          expect(mval(:stats, :pipelines, pipeline_name, :reloads, :last_success_timestamp)).not_to be_nil
        end
      end

      context "and it fails" do
        let(:source_loader) do
          TestSequenceSourceLoader.new(pipeline_config, bad_update_pipeline_config)
        end

        it "increments the global failures" do
          expect { subject.converge_state_and_update }.to change { mval(:stats, :reloads, :failures) }.by(1)
        end

        it "increment the pipeline failures" do
          expect{ subject.converge_state_and_update }.to change { mval(:stats, :pipelines, pipeline_name, :reloads, :failures) }.by(1)
        end
      end
    end

    context "when we successfully reload a pipeline" do
      xit
    end

    context "when we stop a pipeline" do
      let(:source_loader) do
        TestSequenceSourceLoader.new(pipeline_config, [])
      end

      before do
        # Running Pipeline to -> reload pipeline
        expect(subject.converge_state_and_update.success?).to be_truthy
      end

      it "clear pipeline specific metric" do
        expect( mval(:stats, :pipelines, :main, :events)).not_to be_nil
        expect( mval(:stats, :pipelines, :main, :plugins)).not_to be_nil
        expect(subject.converge_state_and_update.success?).to be_truthy
        expect { mval(:stats, :pipelines, :main, :events) }.to raise_error
        expect { mval(:stats, :pipelines, :main, :plugins) }.to raise_error
      end
    end
  end
end