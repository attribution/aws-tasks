require 'aws-sdk-ec2'

module AwsTasks
  class VpcPrefixList
    # Open APIs which allow to detect current IP
    # http://ipv4.whatismyip.akamai.com/
    # https://ifconfig.me/ip
    # https://ipecho.net/plain
    # https://icanhazip.com/
    # http://ident.me/
    IP_LOOKUP_URL = 'http://ipv4.whatismyip.akamai.com/'

    RETRYABLE_ERRORS = [
      Aws::EC2::Errors::IncorrectState,
      Aws::EC2::Errors::PrefixListVersionMismatch,
      Aws::EC2::Errors::PrefixListMaxEntriesExceeded
    ]

    attr_accessor :prefix_list_id, :client

    # AWS CLI methods examples:
    #   aws ec2 get-managed-prefix-list-entries --prefix-list-id pl-036a11494222c3d5c
    #   aws ec2 modify-managed-prefix-list --prefix-list-id pl-036a11494222c3d5c \
    #     --current-version 2 \
    #     --add-entries Cidr=1.1.1.1/32,Description=test
    #   aws ec2 modify-managed-prefix-list --prefix-list-id pl-036a11494222c3d5c \
    #     --current-version 3 \
    #     --remove-entries Cidr=1.1.1.1/32 \
    #     --add-entries Cidr=1.1.1.2/32,Description=test

    def self.get_my_ip
      require 'open-uri'
      URI.open(IP_LOOKUP_URL).read
    end

    # Usage:
    #  add_my_ip { Faraday.get(Services::AwsVpcPrefixList::IP_LOOKUP_URL).body }
    #  add_my_ip('1.1.1.1')
    #  add_my_ip
    def self.add_my_ip(ip=nil, prefix_list_id: nil)
      ip ||= yield if block_given?
      ip ||= get_my_ip
      new(prefix_list_id: prefix_list_id).add_entry(ip)
    end

    def initialize(prefix_list_id: nil, client: nil)
      if ENV['AWS_VPC_COMBO']
        access_key_id, secret_access_key, region, combo_prefix_list_id = ENV['AWS_VPC_COMBO'].split(':')
      end

      @prefix_list_id = prefix_list_id || combo_prefix_list_id || ENV['AWS_VPC_PREFIX_LIST_ID']
      @client = client || init_client(
        access_key_id     || ENV['AWS_VPC_ACCESS_KEY_ID'],
        secret_access_key || ENV['AWS_VPC_SECRET_ACCESS_KEY'],
        region            || ENV['AWS_VPC_REGION']
      )
    end

    def init_client(access_key_id, secret_access_key, region)
      @client ||= Aws::EC2::Client.new(
        access_key_id:     access_key_id,
        secret_access_key: secret_access_key,
        region:            region
      )
    end

    # https://docs.aws.amazon.com/sdk-for-ruby/v3/api/Aws/EC2/Client.html#describe_managed_prefix_lists-instance_method
    def get_prefix_list
      @client.
        describe_managed_prefix_lists(prefix_list_ids: [@prefix_list_id]).
        prefix_lists.
        first
    end

    # https://docs.aws.amazon.com/sdk-for-ruby/v3/api/Aws/EC2/Client.html#get_managed_prefix_list_entries-instance_method
    def get_prefix_list_entries
      @client.
        get_managed_prefix_list_entries(prefix_list_id: @prefix_list_id).
        data.
        entries.
        sort_by { _1.description }
    end

    # https://docs.aws.amazon.com/sdk-for-ruby/v3/api/Aws/EC2/Client.html#modify_managed_prefix_list-instance_method
    def add_entry(ip, remove_entry_cidr: nil, version: nil, max_retries: 5)
      prefix_list = get_prefix_list
      project = ENV['PROJECT_PATH'] || 'unknown'
      dyno = ENV['DYNO'] || 'unknown'
      host = Socket.gethostname

      params = {
        prefix_list_id: @prefix_list_id,
        current_version: (version || prefix_list.version),
        add_entries: [{
          cidr: "#{ip}/32",
          description: "#{Time.now.utc.iso8601} Heroku Instance p:#{project}, d:#{dyno}, h:#{host}"
        }]
      }

      if remove_entry_cidr
        params[:remove_entries] = [{ cidr: remove_entry_cidr }]
      end

      @client.
        modify_managed_prefix_list(params).
        tap { puts "AwsTasks::VpcPrefixList #{ip} added to #{@prefix_list_id}" + (remove_entry_cidr ? ", removed #{remove_entry_cidr}" : '') }
    rescue *RETRYABLE_ERRORS => error
      raise if max_retries < 1
      max_retries -= 1

      # puts "Error #{error}, retrying..."
      if error.kind_of?(Aws::EC2::Errors::PrefixListMaxEntriesExceeded)
        remove_entry_cidr = get_prefix_list_entries.first.cidr
      end

      sleep rand(0.0...2.0)
      retry
    end
  end
end
