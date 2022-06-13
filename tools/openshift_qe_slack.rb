#!/usr/bin/env ruby
require_relative 'common/load_path'

require 'common'
require 'slack-ruby-client'

module BushSlicer
  class CoreosSlack
    include Common::Helper

    attr_accessor :client, :usergroup_id, :token, :user_list, :users_map, :channel

    def initialize(app_name: :cloud_usage_summary, channel: '#team-qe')
      @token = conf.dig('services', 'slack', 'apps').dig(app_name, :token)
      @usergroup_id = conf.dig('services', 'slack', 'usergroup_id')
      @channel = channel
      ### some user's slack IDs don't match their RHT email ID.  To make it
      # simple, just make a list of known users_id that don't have the correct
      # mapping and just merge it with the automated ones
      # this Hash contains mapping of JIRA/polarion component to Slack usergroup id
      @slack_users_hardcoded = YAML.load(open(File.expand_path('creds/slack_users_map.yaml')))

      Slack.configure do |config|
        config.token = @token
        raise 'Missing token' unless config.token
      end
      @client = Slack::Web::Client.new
      @users_map = build_user_map
    end

    def get_group_members(usergroup_id: nil)
      usergroup_id ||= @usergroup_id
      res = self.client.usergroups_users_list(usergroup: usergroup_id)
      res[:users]
    end

    # @return Hash <username -> SLACK_USER_ID>
    def build_user_map(rebuild: false)
      if rebuild
        # first get all users in the openshift-qe slack group
        ocp_qe_users = @client.usergroups_users_list(usergroup: @usergroup_id)
        # now query each USERID to get the corresponding user alias
        users_ids = ocp_qe_users['users']

        threads = []
        slack_users = {}
        users_ids.each do |user_id|
          threads << Thread.new {
            name = client.users_info(user: user_id)['user'].name
            slack_users[name] = user_id
          }
        end
        threads.each(&:join)
      else
        # save request by just loading a predefined user lookup table
        slack_users = YAML.load(open(File.expand_path('creds/slack_users_map.yaml')))
      end
      slack_users.merge!(@slack_users_hardcoded)
      @users_map = slack_users
    end

    # # @return Hash <username -> SLACK_USER_ID>
    # def build_user_map
    #   # first get all users in the openshift-qe slack group
    #   ocp_qe_users = @client.usergroups_users_list(usergroup: @usergroup_id)
    #   # now query each USERID to get the corresponding user alias
    #   users_ids = ocp_qe_users['users']
    #   threads = []
    #   slack_users = {}
    #   users_ids.each do |user_id|
    #     threads << Thread.new {
    #       name = client.users_info(user: user_id)['user'].name
    #       slack_users[name] = user_id
    #     }
    #   end
    #   threads.each(&:join)
    #   slack_users
    # end

    # given a list of long-lived cluster arrays, notify the user in Slack
    # clusters =  [[nil, nil, 29.71, nil],
    #              ["errata463", "7865", 29.98, "geliu"],
    #              ["giri1503v48", "140921", 28.72, "gkarager"],
    #              ["asood-03-15-1", "7889", 27.33, "asood"],
    #              ["kkulkarni", "8163", 26.63, "kkulkarni"],
    #              ["walid4621nfdb", "7953", 21.47, "wabouham"]]
    def notify_longlived_clusters_to_users(clusters: nil)
      # longlived-clusters Hash
      lc = {}
      clusters.each do |cluster|
        if cluster[3].nil?
          user_name = "Unknown"
        else
          user_name = cluster[3]
        end
        lc[user_name] = [] if lc[user_name].nil?
        lc[user_name] << {uptime: cluster[2], job_id: cluster[1]}
      end
      lc.each do |k, v|
        msg = "<@#{self.user_id(k)}>, your long-lived clusters #{v}"
        self.post_msg(msg: msg, channel: self.channel)
      end
    end

    # @return Slack user ID, given a user alias
    def user_id(user_name)
      @users_map.dig(user_name)
    end

    def post_msg(msg: nil, channel: self.channel, as_blocks: false)
      unless as_blocks
        block_msg = [{"type": "section", "text": {"type": "mrkdwn", "text": "```#{msg}```"}}]
        self.client.chat_postMessage(channel: channel, blocks: block_msg, as_user: true)
      else
        self.client.chat_postMessage(channel: channel, text: msg, as_user: true)
      end
    end
  end
end

if __FILE__ == $0
  # default to ocp-qe-clusters channel.
  slack = BushSlicer::CoreosSlack.new
  # set the channel: parameter to direct to the channel where the message to be
  # posted
  #slack = BushSlicer::CoreosSlack.new(channel: '#pruan_slack_bot_sandbox')
  #slack = OpenshiftQE::CoreosSlack.new #(channel: '#ocp-qe-scale-ci-results')
  #slack.build_user_lookup_table
  #slack.build_user_lookup_table(pre_compiled_result: 'creds/slack_users_map.yaml')
  # clusters =  [[nil, nil, 29.71, nil],
  #                ["errata463", "7865", 29.98, "geliu"],
  #                ["giri1503v48", "140921", 28.72, "gkarager"],
  #                ["asood-03-15-1", "7889", 27.33, "asood"],
  #                ["kkulkarni", "8163", 26.63, "kkulkarni"],
  #                ["walid4621nfdb", "7953", 21.47, "wabouham"]]

  clusters =  [
                 [nil, nil, 29.71, nil],
                 ["errata463", "7865", 29.98, "pruan"],
                 ]
  test_msg = "This is a test"
  slack.post_msg(msg: test_msg, channel: "#pruan_slack_bot_sandbox", as_blocks: true)
  slack.post_msg(msg: test_msg, channel: "#pruan_slack_bot_sandbox")
#  slack.notify_longlived_clusters_to_users(clusters: clusters)
end
