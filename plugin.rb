# name: Panel groups
# about: Synchronize groups with API
# version: 0.0.1
# authors: Piotr Szmielew

require 'open-uri'
require 'json'

module ::PanelGroups
  def self.connect
    uri = SiteSetting.panel_uri
  end

  def self.update_groups!
    return unless SiteSetting.panel_groups_enabled
    
    @groups_to_clear = Group.where(name: ['stazysta', 'sympatyk']).pluck(:id)
    
    groups = JSON.parse(open(self.connect() + "/api/groups/groups?token=" + SiteSetting.panel_token).read)
    
    groups.each_pair do |name, external_id|
      self.update_from_panel_entry name, external_id
    end
   
    query = "UPDATE groups g SET user_count = (SELECT COUNT(user_id) FROM group_users gu WHERE gu.group_id = g.id)"
   
    ActiveRecord::Base.connection_pool.with_connection { |con| con.exec_query(query) }

    # ldap_group_names = Array.new
#     ldap.search(:base => base_dn) do |entry|
#       self.update_from_panel_entry entry
#       ldap_group_names << entry.cn.first
#     end
#     orphaned_groups = GroupCustomField.where(name: 'external_id')
#                                       .where.not(value: ldap_group_names)
#     orphaned_groups.each do |f|
#       delete_group f.group
#     end
  end

  def self.update_from_panel_entry(name, external_id)
    users = JSON.parse(open(self.connect() + "/api/groups/groups/#{external_id}?token=" + SiteSetting.panel_token).read)
    members = users.collect do |m|
      record = SingleSignOnRecord.find_by external_id: m
      next unless record
      User.find record.user_id
    end
    members.compact! # remove nils from users not in discourse

    # Find existing group or create a new one
    field = GroupCustomField.find_by(name: 'external_id', 
                                     value: external_id)
    ActiveRecord::Base.transaction do 
      if field and field.group
        group = field.group
      else
        g_name = UserNameSuggester.suggest(name)
        puts "panel_group: Creating new group '#{g_name}' for external '#{name}'"

        group = Group.new name: g_name
        group.visible = true
        group.custom_fields['external_id'] = external_id
        group.save!
      end
      if @groups_to_clear.include? group.id
        (group.users - members).each do |member|
          member.title = '' if member.title = group.title
          member.save!
        end
      group.users = members
      group.save!
    end
  end


  # def self.delete_group(group)
 #    puts "ldap_group: Deleting '#{group.name}'"
 #
 #    if group.custom_fields.has_key? 'category_id'
 #      # Hide category but do not delete it, in case it has to be recovered
 #      cat = Category.find group.custom_fields['category_id']
 #      cat.set_permissions(:admins => :readonly)
 #      cat.parent_category = Category.find(
 #        SiteSetting.ldap_group_deleted_category_parent_id)
 #      cat.save!
 #    end
 #    group.destroy
 #  end
end

after_initialize do
  module ::PanelGroups
    class UpdateJob < ::Jobs::Scheduled
      every 1.hour

      def execute(args)
        return unless SiteSetting.panel_groups_enabled
        PanelGroups.update_groups!
      end
    end
  end
end
