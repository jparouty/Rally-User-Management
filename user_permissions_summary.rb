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

$userslist_filename = ARGV[0]

$input_mode = :allusers

if $userslist_filename != nil
  if File.exists?(File.dirname(__FILE__) + "/" + $userslist_filename) == false
    puts "User List file #{$userslist_filename} not found. Exiting."
    exit
  else
    $input_mode = :userslist
  end  
end

# Mode options:
# :standard => Outputs permission attributes only
# :extended => Outputs enhanced field list including Enabled/Disabled,NetworkID,Role,CostCenter,Department,OfficeLocation
$summary_mode = :extended

$type_workspacepermission = "WorkspacePermission"
$type_projectpermission   = "ProjectPermission"
$standard_output_fields   =  %w{UserID LastName FirstName DisplayName Disabled Type WorkspaceName WorkspaceRole ProjectName ProjectRole TeamMember ObjectID}
$extended_output_fields   =  %w{UserID LastName FirstName DisplayName Disabled Type WorkspaceName WorkspaceRole ProjectName ProjectRole TeamMember ObjectID NetworkID Role CostCenter Department OfficeLocation}

$my_output_file           = "user_permissions_summary.txt"
$my_delim                 = "\t"

$initial_fetch            = "UserName,FirstName,LastName,DisplayName"
$standard_detail_fetch    = "UserName,FirstName,LastName,DisplayName,UserPermissions,Name,Role,Workspace,ObjectID,State,Project,ObjectID,State,TeamMemberships,Disabled"
$extended_detail_fetch    = "UserName,FirstName,LastName,DisplayName,UserPermissions,Name,Role,Workspace,ObjectID,State,Project,ObjectID,State,TeamMemberships,Disabled,NetworkID,Role,CostCenter,Department,OfficeLocation"

$enabled_only_filter = "(Disabled = \"False\")"

#Setup role constants
$ADMIN = 'Admin'
$USER = 'User'
$EDITOR = 'Editor'
$VIEWER = 'Viewer'
$NOACCESS = 'No Access'
$TEAMMEMBER_YES = 'Yes'
$TEAMMEMBER_NO = 'No'
$TEAMMEMBER_NA = 'N/A'

if $summary_mode == :extended then
  $summarize_enabled_only = false
  $output_fields = $extended_output_fields
  $detail_fetch = $extended_detail_fetch
else
  # For purposes of speed/efficiency, summarize Enabled Users ONLY
  $summarize_enabled_only = true
  $output_fields = $standard_output_fields
  $detail_fetch = $standard_detail_fetch
end

if $my_delim == nil then $my_delim = "," end

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

begin
  # Load (and maybe override with) my personal/private variables from a file...
  my_vars= File.dirname(__FILE__) + "/my_vars.rb"
  if FileTest.exist?( my_vars ) then require my_vars end

  log_file = File.open("user_permissions_summary.log", "a")
  @logger = Logger.new MultiIO.new(STDOUT, log_file)

  @logger.level = Logger::INFO #DEBUG | INFO | WARN | FATAL

  #==================== Making a connection to Rally ====================
  config                  = {:base_url => $my_base_url}
  config[:username]       = $my_username
  config[:password]       = $my_password
  config[:version]        = $wsapi_version
  config[:headers]        = $my_headers #from RallyAPI::CustomHttpHeader.new()

  @logger.info "Connecting to Rally: #{$my_base_url} as #{$my_username}..."

  @rally = RallyAPI::RallyRestJson.new(config)

	#Helper Methods
	@logger.info "Instantiating User Helper..."
	@uh = UserHelper.new(@rally, @logger, true)

  #==================== Querying Rally ==========================
  user_query = RallyAPI::RallyQuery.new()
  user_query.type = :user
  user_query.fetch = $initial_fetch
  user_query.page_size = 200 #optional - default is 200
  user_query.limit = 50000 #optional - default is 99999
  user_query.order = "UserName Asc"

	# Note: pre-fetching Workspaces and Projects can help performance
	# Plus, we pretty much have to do it because later Workspace/Project queries
	# in UserHelper, that don't come off the Subscription List, will fail
	# unless they are in the user's Default Workspace
	@logger.info "Caching workspaces and projects..."
	@uh.cache_workspaces_projects()

  # Query for users
  @logger.info "Running initial query of users..."

  if $input_mode == :allusers then
    # Filter for enabled only
    if $summarize_enabled_only then
      user_query.query_string = $enabled_only_filter
      number_found_suffix = "Enabled Users."
    else
      number_found_suffix = "Users."
    end
    initial_user_query_results = @rally.find(user_query)
    n_users = initial_user_query_results.total_result_count
  elsif $input_mode == :userslist then
    number_found_suffix = "Users."
    
    input  = CSV.read($userslist_filename, {:col_sep => $my_delim })

    header = input.first #ignores first line
    rows   = []
    (1...input.size).each { |i| rows << CSV::Row.new(header, input[i]) }

    these_users = []
    rows.each do |row|
      username_field = row[header[0]]
      if username_field.nil? then
        required_field_isnil = true
        required_nil_fields += "UserName"
      else
        username = username_field.strip
      end
      
      if required_field_isnil then
        @logger.warning "One or more required fields: "
        @logger.warning required_nil_fields
        @logger.warning "Is missing! Skipping this row..."
        return
      end

      this_user = @uh.find_user(username)
      these_users.push(this_user)
    end
    initial_user_query_results = these_users
    n_users = initial_user_query_results.length
  end
  
  # Summarize number of found users
  @logger.info "Found a total of #{n_users} " + number_found_suffix
  
  # Set a default value for workspace_name
  workspace_name = "N/A"

	count = 1
	notify_increment = 10

	# loop through all users and output permissions summary
	@logger.info "Summarizing users and writing extended permission summary output file..."

	# Open file for output of summary
	# Output CSV header
	summary_csv = CSV.open($my_output_file, "w", {:col_sep => $my_delim})
	summary_csv << $output_fields
	
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
			if notify_remainder==0 then @logger.info "Processed #{count} of #{n_users} " + number_found_suffix end
			count+=1
		
			workspaces = @uh.get_cached_workspaces()
			
			workspaces.each do | this_cached_workspace |
				this_workspace = this_cached_workspace.last
						
				if this_user.UserPermissions.include?("#{this_workspace.Name} #{$USER}") == true then
					workspace_permission_role = $USER
				elsif this_user.UserPermissions.include?("#{this_workspace.Name} #{$ADMIN}") == true then
					workspace_permission_role = $ADMIN
				else 
					workspace_permission_role = $NOACCESS
				end
				
				output_record = []
				output_record << this_user.UserName
				output_record << this_user.LastName
				output_record << this_user.FirstName
				output_record << this_user.DisplayName
				output_record << this_user.Disabled
				output_record << $type_workspacepermission
				output_record << this_workspace.Name
				output_record << workspace_permission_role
				output_record << $TEAMMEMBER_NA
				output_record << $TEAMMEMBER_NA
				output_record << $TEAMMEMBER_NA
				output_record << this_workspace.ObjectID
				if $summary_mode == :extended then
					output_record << this_user.NetworkID
					output_record << this_user.Role
					output_record << this_user.CostCenter
					output_record << this_user.Department
					output_record << this_user.OfficeLocation
				end					
				summary_csv << output_record
				
				these_projects = @uh.get_open_projects(this_workspace)
				if these_projects != nil then
					these_projects.each do | this_project |
													
						# Grab the ObjectID
						object_id = this_project.ObjectID
            
            if this_user.UserPermissions.include?("#{this_project.Name} #{$VIEWER}") == true then
              this_permission = this_user.UserPermissions["#{this_project.Name} #{$VIEWER}"]
              if this_permission.length == nil then
                if this_permission["Project"].Workspace.ObjectID == this_workspace.ObjectID then
                  project_permission_role = $VIEWER
                  team_member = $TEAMMEMBER_NO
                else
                  project_permission_role = $NOACCESS	
      						team_member = $TEAMMEMBER_NO
                end
              else
                this_permission.each do | this_duplicate_permission |
                  if this_duplicate_permission["Project"].ObjectID == this_project.ObjectID && this_duplicate_permission["Project"].Workspace.ObjectID == this_workspace.ObjectID then
                    project_permission_role = $VIEWER
                    team_member = $TEAMMEMBER_NO
                  else
                    project_permission_role = $NOACCESS	
                  	team_member = $TEAMMEMBER_NO
                  end
                end
              end
						elsif this_user.UserPermissions.include?("#{this_project.Name} #{$EDITOR}") == true then
              this_permission = this_user.UserPermissions["#{this_project.Name} #{$EDITOR}"]
              if this_permission.length == nil then
                if this_permission["Project"].Workspace.ObjectID == this_workspace.ObjectID then
                  project_permission_role = $EDITOR
                
                  # Convert OID to a string so is_team_member can do string comparison
                  object_id_string = object_id.to_s
              
                  # Determine if user is a team member on this project
                  team_member = @uh.is_team_member?(this_user, object_id_string)
                else
                  project_permission_role = $NOACCESS	
                	team_member = $TEAMMEMBER_NO                
                end
              else
                this_permission.each do | this_duplicate_permission |
                  if this_duplicate_permission["Project"].ObjectID == this_project.ObjectID && this_duplicate_permission["Project"].Workspace.ObjectID == this_workspace.ObjectID then
                    project_permission_role = $EDITOR
                  
                    # Convert OID to a string so is_team_member can do string comparison
                    object_id_string = object_id.to_s
                
                    # Determine if user is a team member on this project
                    team_member = @uh.is_team_member?(this_user, object_id_string)
                  else
                    project_permission_role = $NOACCESS	
                  	team_member = $TEAMMEMBER_NO                  
                  end
                end
              end
						else
							project_permission_role = $NOACCESS	
							team_member = $TEAMMEMBER_NO
						end
						
						output_record = []
						output_record << this_user.UserName
						output_record << this_user.LastName
						output_record << this_user.FirstName
						output_record << this_user.DisplayName
						output_record << this_user.Disabled
						output_record << $type_projectpermission
						output_record << this_workspace.Name
						output_record << workspace_permission_role
						output_record << this_project.Name
						output_record << project_permission_role
						output_record << team_member
						output_record << object_id
						if $summary_mode == :extended then
							output_record << this_user.NetworkID
							output_record << this_user.Role
							output_record << this_user.CostCenter
							output_record << this_user.Department
							output_record << this_user.OfficeLocation
						end		
						summary_csv << output_record
					end
				end
			end
		# User not found in follow-up detail Query - skip this user 
		else
			@logger.info "User: #{this_user_name} not found in follow-up query. Skipping..."
			next
		end        
	end

	@logger.info "Done! Permission summary written to #{$my_output_file}."  
  log_file.close
  
rescue Exception => ex
  puts ex.backtrace
  puts ex.message
end