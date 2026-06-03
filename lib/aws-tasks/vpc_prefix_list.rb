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
      Aws::EC2::Errors::InvalidPrefixListModification,
      Aws::EC2::Errors::PrefixListVersionMismatch,
      Aws::EC2::Errors::PrefixListMaxEntriesExceeded
    ]

    MAX_RETRIES = 5
    # Cap cumulative worst-case backoff at one minute. Each retry sleeps one
    # doubling octave longer (random-exponent backoff below), so the octave maxes
    # sum to RETRY_BASE_SLEEP * (2^(MAX_RETRIES+1) - 2). Derive the base from the
    # cap so changing MAX_RETRIES re-fits the same budget.
    RETRY_MAX_TOTAL = 60.0
    RETRY_BASE_SLEEP = RETRY_MAX_TOTAL / (2**(MAX_RETRIES + 1) - 2)

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
      new(prefix_list_id: prefix_list_id).modify(add: [ip])
    end

    # Usage:
    #  remove_my_ip { Faraday.get(Services::AwsVpcPrefixList::IP_LOOKUP_URL).body }
    #  remove_my_ip('1.1.1.1')
    #  remove_my_ip
    def self.remove_my_ip(ip=nil, prefix_list_id: nil)
      ip ||= yield if block_given?
      ip ||= get_my_ip
      new(prefix_list_id: prefix_list_id).modify(remove: [ip])
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

    # Add and/or remove the given IPs in a single modify call. Reconciles
    # against the live list every attempt: skips adds already present, skips
    # removes no longer there, and never removes a cidr that's also being added
    # (dyno IP reuse). Versions, retries, and eviction-when-full are handled
    # here, so callers just pass what they want present and gone.
    # https://docs.aws.amazon.com/sdk-for-ruby/v3/api/Aws/EC2/Client.html#modify_managed_prefix_list-instance_method
    def modify(add: [], remove: [])
      return if add.empty? && remove.empty?

      want_add    = add.map { entry_for(_1) }
      want_remove = remove.map { entry_for(_1)[:cidr] }

      attempt = 0
      begin
        prefix_list = get_prefix_list
        present     = get_prefix_list_entries.map(&:cidr) # sorted oldest-first
        add_cidrs   = want_add.map { _1[:cidr] } # requested adds, before present-filtering

        adds    = want_add.reject { present.include?(_1[:cidr]) }
        removes = want_remove.select { present.include?(_1) }.reject { add_cidrs.include?(_1) }

        # The list has a hard max_entries cap. If the result would overflow it,
        # evict the oldest entries we aren't otherwise touching to make room —
        # proactively, since we already know the size, rather than letting AWS
        # reject the modify and reacting to it.
        overflow = present.size + adds.size - removes.size - prefix_list.max_entries
        if overflow > 0
          removes += present.reject { add_cidrs.include?(_1) || removes.include?(_1) }.first(overflow)
        end

        return if adds.empty? && removes.empty?

        params = { prefix_list_id: @prefix_list_id, current_version: prefix_list.version }
        params[:add_entries]    = adds unless adds.empty?
        params[:remove_entries] = removes.map { { cidr: _1 } } unless removes.empty?

        @client.
          modify_managed_prefix_list(params).
          tap { puts "AwsTasks::VpcPrefixList #{@prefix_list_id} added #{adds.map { _1[:cidr] }}, removed #{removes}" }
      rescue *RETRYABLE_ERRORS
        raise if attempt >= MAX_RETRIES

        # AWS allows only one modification at a time, so concurrent dynos collide
        # (version mismatch / incorrect state, or a race that fills the list).
        # Back off and retry; the next attempt re-reads the list and recomputes
        # everything, including eviction. First retry near-instant, each ~2x
        # longer, with a random fractional exponent so workers don't re-collide
        # in lockstep. Worst case ~MAX_RETRIES rounds.
        sleep RETRY_BASE_SLEEP * (2 ** (attempt + rand))
        attempt += 1
        retry
      end
    end

    private

    # The { cidr, description } entry for an IP; the description carries this
    # dyno's metadata (used to order entries oldest-first for eviction).
    def entry_for(ip)
      project = ENV['PROJECT_PATH'] || 'unknown'
      dyno = ENV['DYNO'] || 'unknown'
      host = Socket.gethostname

      {
        cidr: "#{ip}/32",
        description: "#{Time.now.utc.iso8601} Heroku Instance p:#{project}, d:#{dyno}, h:#{host}"
      }
    end
  end
end
