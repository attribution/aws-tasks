# TODO remove/replace Rollbar with callback?
module AwsTasks
  class SecurityGroup
    # Open APIs which allow to detect current IP
    # http://ipv4.whatismyip.akamai.com/
    # https://ifconfig.me/ip
    # https://ipecho.net/plain
    # https://icanhazip.com/
    # http://ident.me/
    IP_LOOKUP_URL = 'http://ipv4.whatismyip.akamai.com/'

    attr_accessor :security_group_id, :port, :client

    # AWS CLI methods
    # aws ec2 describe-security-groups --group-ids sg-0dca03885a00d9ade
    # aws ec2 authorize-security-group-ingress \
    #     --group-id sg-0dca03885a00d9ade \
    #     --protocol tcp \
    #     --port 5432 \
    #     --cidr 3.219.217.67/32

    def self.get_my_ip
      # URI.open(IP_LOOKUP_URL).read # alternative
      Faraday.new(IP_LOOKUP_URL).get.body
    end

    def self.authorize_my_ip_for_ingress
      new.authorize_ingress_ip(get_my_ip)
    end

    def initialize(security_group_id: nil, port: nil, client: nil)
      if ENV['AWS_SECURITY_GROUP_COMBO']
        access_key_id, secret_access_key, region, security_group_id, port = ENV['AWS_SECURITY_GROUP_COMBO'].split(':')
      end

      @security_group_id = security_group_id || ENV['AWS_SECURITY_GROUP_ID']
      @port              = port              || ENV['AWS_SECURITY_GROUP_PORT']
      @client            = client || init_client(
        access_key_id     || ENV['AWS_SECURITY_GROUP_ACCESS_KEY_ID'],
        secret_access_key || ENV['AWS_SECURITY_GROUP_SECRET_ACCESS_KEY'],
        region            || ENV['AWS_SECURITY_GROUP_REGION']
      )
    end

    def init_client(access_key_id, secret_access_key, region)
      @client ||= Aws::EC2::Client.new(
        access_key_id:     access_key_id,
        secret_access_key: secret_access_key,
        region:            region
      )
    end

    def authorize_ingress_ip(ip, retries: 0)
      project = ENV['PROJECT_PATH'] || 'unknown'
      dyno = ENV['DYNO'] || 'unknown'
      host = Socket.gethostname

      @client.authorize_security_group_ingress({
        group_id: @security_group_id,
        ip_permissions: [{
          from_port: @port,
          to_port: @port,
          ip_protocol: 'tcp',
          ip_ranges: [{
            cidr_ip: "#{ip}/32",
            description: "#{Time.now.to_i} Heroku Instance p:#{project}, d:#{dyno}, h:#{host}",
          }]
        }]
      })
    rescue Aws::EC2::Errors::InvalidPermissionDuplicate
      # nothing to do - IP already has access
    rescue Aws::EC2::Errors::RulesPerSecurityGroupLimitExceeded => error
      retries += 1

      if retries >= 3
        raise
      else
        Rollbar.info(error, {
          tries: retries,
          security_group_id: @security_group_id,
          port: @port,
          project: project
        })

        revoke_oldest_security_group_rule
        retry
      end
    end

    # describe security group
    # result = cli.describe_security_groups(group_ids: ['sg-0dca03885a00d9ade'])
    # result.security_groups.first.ip_permissions.each {|sgr| p sgr}

    # list ingress security_group_rules sorted by description
    def list_security_group_rules
      @client.
        describe_security_group_rules(filters: [{ name: 'group-id', values: [@security_group_id] }]).
        security_group_rules.
        select{ _1.description.present? && _1.is_egress == false }.
        sort_by(&:description)
    end

    def revoke_security_group_rules(ids)
      @client.
        revoke_security_group_ingress(
          group_id: @security_group_id,
          security_group_rule_ids: Array.wrap(ids)
        ).
        tap { Rollbar.info('Removed Security Group Rule', { security_group_rules: ids }) }
    end

    def revoke_oldest_security_group_rule
      oldest_sgr = list_security_group_rules.first
      return unless oldest_sgr

      revoke_security_group_rules(oldest_sgr.security_group_rule_id)
    end
  end
end
