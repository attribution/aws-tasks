require 'spec_helper'

describe AwsTasks::VpcPrefixList do
  let(:client) { Aws::EC2::Client.new(stub_responses: true, region: 'us-east-1') }
  let(:subject) { described_class.new(prefix_list_id: 'pl-test', client: client) }

  before do
    client.stub_responses(:describe_managed_prefix_lists,
      prefix_lists: [{ prefix_list_id: 'pl-test', version: 7, max_entries: 100 }])
    client.stub_responses(:get_managed_prefix_list_entries, entries: [])
  end

  def capture_modify
    captured = nil
    client.stub_responses(:modify_managed_prefix_list, lambda do |context|
      captured = context.params
      {}
    end)
    yield
    captured
  end

  describe '#modify' do
    it 'adds new ips and removes present ones in one modify at the current version' do
      client.stub_responses(:get_managed_prefix_list_entries,
        entries: [{ cidr: '9.9.9.9/32', description: 'old' }])

      params = capture_modify { subject.modify(add: ['1.1.1.1', '2.2.2.2'], remove: ['9.9.9.9']) }

      expect(params[:current_version]).to eq 7
      expect(params[:add_entries].map { _1[:cidr] }).to eq ['1.1.1.1/32', '2.2.2.2/32']
      expect(params[:add_entries].first[:description]).to include('Heroku Instance')
      expect(params[:remove_entries]).to eq [{ cidr: '9.9.9.9/32' }] # description discarded
    end

    it 'skips adding an ip that is already present' do
      client.stub_responses(:get_managed_prefix_list_entries,
        entries: [{ cidr: '1.1.1.1/32', description: 'here' }])

      params = capture_modify { subject.modify(add: ['1.1.1.1', '2.2.2.2']) }

      expect(params[:add_entries].map { _1[:cidr] }).to eq ['2.2.2.2/32']
    end

    it 'skips removing an ip that is no longer on the list' do
      expect(client).not_to receive(:modify_managed_prefix_list) # entries stubbed empty
      subject.modify(remove: ['9.9.9.9'])
    end

    it 'never removes an ip that is also being added (dyno IP reuse)' do
      client.stub_responses(:get_managed_prefix_list_entries,
        entries: [{ cidr: '1.1.1.1/32', description: 'old' }])

      params = capture_modify { subject.modify(add: ['1.1.1.1'], remove: ['1.1.1.1']) }

      # already present so not re-added, and not removed because a starter wants it
      expect(params).to be_nil
    end

    it 'is a no-op when there is nothing to add or remove' do
      expect(client).not_to receive(:modify_managed_prefix_list)
      subject.modify
    end

    it 'evicts the oldest entries up front when adding would exceed max_entries' do
      client.stub_responses(:describe_managed_prefix_lists,
        prefix_lists: [{ prefix_list_id: 'pl-test', version: 7, max_entries: 2 }])
      client.stub_responses(:get_managed_prefix_list_entries, entries: [
        { cidr: '10.0.0.1/32', description: '2020-01-01T00:00:00Z oldest' },
        { cidr: '10.0.0.2/32', description: '2021-01-01T00:00:00Z newer' }
      ])

      params = capture_modify { subject.modify(add: ['3.3.3.3']) }

      expect(params[:add_entries].map { _1[:cidr] }).to eq ['3.3.3.3/32']
      expect(params[:remove_entries]).to eq [{ cidr: '10.0.0.1/32' }] # oldest evicted to make room
    end
  end

  describe 'retry on version mismatch' do
    it 're-attempts the modify and succeeds' do
      allow(subject).to receive(:sleep)
      calls = 0
      client.stub_responses(:modify_managed_prefix_list, lambda do |context|
        calls += 1
        raise Aws::EC2::Errors::PrefixListVersionMismatch.new(context, 'mismatch') if calls == 1
        {}
      end)

      subject.modify(add: ['1.1.1.1'])

      expect(calls).to eq 2
    end
  end
end
