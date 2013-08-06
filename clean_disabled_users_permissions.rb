#include for rally json library gem
require 'rally_api'
require 'csv'
require 'logger'
require File.dirname(__FILE__) + "/user_helper.rb"

#Setting custom headers
$headers = RallyAPI::CustomHttpHeader.new()
$headers.name           = "Ruby User Permissions Summary Report"
$headers.vendor         = "Rally Labs"
$headers.version        = "0.10"

#API Version
$wsapi_version          = "1.41"

# constants
$my_base_url            = "https://rally1.rallydev.com/slm"
$my_username            = "user@company.com"
$my_password            = "password"
$my_headers             = $headers
$my_page_size           = 200
$my_limit               = 50000

$type_workspacepermission = "WorkspacePermission"
$type_projectpermission   = "ProjectPermission"

$initial_fetch   = "UserName,FirstName,LastName,DisplayName"
$detail_fetch    = "UserName,FirstName,LastName,DisplayName,UserPermissions,Name,Role,Workspace,ObjectID,State,Project,ObjectID,State,TeamMemberships"

#Setup role constants
$ADMIN = 'Admin'
$USER = 'User'
$EDITOR = 'Editor'
$VIEWER = 'Viewer'
$NOACCESS = 'No Access'
$TEAMMEMBER_YES = 'Yes'
$TEAMMEMBER_NO = 'No'
$TEAMMEMBER_NA = 'N/A'

# Class to help Logger output to both STOUT and to a file
class MultiIO
  def initialize(*targets)
     @targets = targets
  end

  def write(*args)
    @targets.each {|t| t.write(*args)}
  end

  def close
    @targets.each(&:close)
  end
end

def strip_role_from_permission(str)
  # Removes the role from the Workspace,ProjectPermission String so we're left with just the
  # Workspace/Project Name
  str.gsub(/\bAdmin|\bUser|\bEditor|\bViewer/,"").strip
end

def is_team_member(project_oid, team_memberships)

  # Default values
  is_member = false
  return_value = "No"

  # First check if team_memberships are nil then loop through and look for a match on
  # Project OID
  if team_memberships != nil then

    team_memberships.each do |this_membership|
      this_membership_ref = this_membership._ref

      # Grab the Project OID off of the ref URL
      this_membership_oid = this_membership_ref.split("\/")[-1].split("\.")[0]

      if this_membership_oid == project_oid then
        is_member = true
      end
    end
  end

  if is_member then return_value = "Yes" end
  return return_value
end

begin
  # Load (and maybe override with) my personal/private variables from a file...
  my_vars= File.dirname(__FILE__) + "/my_vars.rb"
  if FileTest.exist?( my_vars ) then require my_vars end

  log_file = File.open("clean_disabled_users_permissions.log", "a")
  @logger = Logger.new MultiIO.new(STDOUT, log_file)

  @logger.level = Logger::INFO #DEBUG | INFO | WARNING | FATAL
  
  #==================== Making a connection to Rally ====================
  config                  = {:base_url => $my_base_url}
  config[:username]       = $my_username
  config[:password]       = $my_password
  config[:version]        = $wsapi_version
  config[:headers]        = $my_headers #from RallyAPI::CustomHttpHeader.new()

  puts "Connecting to Rally: #{$my_base_url} as #{$my_username}..."

  @rally = RallyAPI::RallyRestJson.new(config)

  #==================== Querying Rally ==========================
  user_query = RallyAPI::RallyQuery.new()
  user_query.type = :user
  user_query.fetch = $initial_fetch
  user_query.page_size = 200 #optional - default is 200
  user_query.limit = 50000 #optional - default is 99999
  user_query.order = "UserName Asc"
  user_query.query_string = "(Disabled = \"True\")"
  
  # Query for users
  puts "Running initial query of users..."

  initial_user_query_results = @rally.find(user_query)
  n_users = initial_user_query_results.total_result_count
  
  # Summarize number of found users
  
  puts "Found a total of #{n_users} Disabled Users"
  
  #Helper Methods
	puts "Instantiating User Helper..."
	@uh = UserHelper.new(@rally, @logger, true)
  
	count = 1
	notify_increment = 10

  # Run stepwise query of users
	# More expansive fetch on single-user query
	user_query.fetch = $detail_fetch

  initial_user_query_results.each do | this_user_init |
  	# Setup query parameters for Rally query of detailed user info
		this_user_name = this_user_init["UserName"]
		query_string = "(UserName = \"#{this_user_name}\")"
		user_query.query_string = query_string
		
		# Query Rally for single-user detailed info, including Permissions, Projects, and
		# Team Memberships
		detail_user_query_results = @rally.find(user_query)
		
		number_found = detail_user_query_results.total_result_count
		if number_found > 0 then
			this_user = detail_user_query_results.first
			
			# Summarize where we are in processing
			notify_remainder=count%notify_increment
			if notify_remainder==0 then puts "Processed #{count} of #{n_users} Disabled Users" end
			count+=1
			
			user_permissions = this_user.UserPermissions
			puts "#{this_user} has #{user_permissions.length} permissions"
      user_permissions.each do | this_permission |
        # Set default for team membership
        team_member = "No"
      
        if this_permission._type == $type_workspacepermission then
          workspace = this_permission["Workspace"]          
          team_member = "N/A"
          
          workspace_state = workspace["State"]

          if workspace_state == "Closed"
            next          
          end  
          
          @uh.update_workspace_permissions(workspace, this_user, $NOACCESS, false)
          
        else
          project = this_permission["Project"]
          
          project_state = project["State"]
          
          if project_state == "Closed"
            next          
          end
          
          # Grab the ObjectID
          object_id = project["ObjectID"]
          # Convert OID to a string so is_team_member can do string comparison
          object_id_string = object_id.to_s
          
          # Determine if user is a team member on this project
          these_team_memberships = this_user["TeamMemberships"]
          team_member = is_team_member(object_id_string, these_team_memberships)
          
          if team_member == $TEAMMEMBER_YES
            @uh.update_team_membership(this_user, object_id_string, project.Name, $TEAMMEMBER_NO)
          end
                    
          @uh.update_project_permissions(project, this_user, $NOACCESS = 'No Access', false)
        end
      end  
		end	
  end
end