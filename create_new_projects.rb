#include for rally json library gem
require 'rally_api'
require 'csv'
require 'logger'
require File.dirname(__FILE__) + "/user_helper.rb"

# User-defined variables
$my_base_url                        = "https://rally1.rallydev.com/slm"
$my_username                        = "user@company.com"
$my_password                        = "password"

# Field delimiter for permissions file
$my_delim                           = "\t"

#Setting custom headers
$headers                            = RallyAPI::CustomHttpHeader.new()
$headers.name                       = "Ruby User Management Tool 2"
$headers.vendor                     = "Rally Labs"
$headers.version                    = "0.10"

#API Version
$wsapi_version                      = "1.41"

# Fetch/query/create parameters
$my_headers                         = $headers
$my_page_size                       = 200
$my_limit                           = 50000
$user_create_delay                  = 0 # seconds buffer time after creating user and before adding permissions

#Setup constants
$workspace_permission_type          = "WorkspacePermission"
$project_permission_type            = "ProjectPermission"

$initial_fetch   = "UserName,FirstName,LastName,DisplayName"
$detail_fetch    = "UserName,FirstName,LastName,DisplayName,UserPermissions"


# Mode options:
# :none => do not set project permissions
# :allusersviewers => all workspace users are set to viewers for the new project
# :alluserseditors => all workspace users are set to viewers for the new project
$permissions_mode                   = :allusersviewers

#Setup role constants
$ADMIN = 'Admin'
$USER = 'User'
$EDITOR = 'Editor'
$VIEWER = 'Viewer'
$NOACCESS = 'No Access'
$TEAMMEMBER_YES = 'Yes'
$TEAMMEMBER_NO = 'No'
$TEAMMEMBER_NA = 'N/A'

$projectslist_filename = ARGV[0]

if $projectslist_filename != nil
  if File.exists?(File.dirname(__FILE__) + "/" + $projectslist_filename) == false
    puts "Project List file #{$projectslist_filename} not found. Exiting."
    exit
  end  
end

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

begin
 # Load (and maybe override with) my personal/private variables from a file...      
  my_vars= File.dirname(__FILE__) + "/my_vars.rb"
  if FileTest.exist?( my_vars ) then require my_vars end

  log_file = File.open("create_new_projects.log", "a")
  @logger = Logger.new MultiIO.new(STDOUT, log_file)

  @logger.level = Logger::INFO #DEBUG | INFO | WARN | FATAL

  #==================== Making a connection to Rally ====================
  config                  = {:base_url => $my_base_url}
  config[:username]       = $my_username
  config[:password]       = $my_password
  config[:headers]        = $my_headers #from RallyAPI::CustomHttpHeader.new()
  config[:version]        = $wsapi_version

  workspace_query    		           = RallyAPI::RallyQuery.new()
  workspace_query.project		   = nil
  workspace_query.type		           = :workspace
  workspace_query.fetch		           = "Name,State,ObjectID"
  
  @logger.info "Connecting to #{$my_base_url} as #{$my_username}..."
  @rally = RallyAPI::RallyRestJson.new(config)

  #Helper Methods
  @logger.info "Instantiating User Helper..."
  @uh = UserHelper.new(@rally, @logger, true)
  
  input  = CSV.read($projectslist_filename, {:col_sep => $my_delim })

  header = input.first #ignores first line
  rows   = []
  (1...input.size).each { |i| rows << CSV::Row.new(header, input[i]) }

  rows.each do |row|
    projectname_field = row[header[0]]
    workspacename_field = row[header[1]]
    workspaceoid_field = row[header[2]]
    parentname_field = row[header[3]]
    parentoid_field = row[header[4]]
    owneruid_field = row[header[5]]
    
    # Check to see if any required fields are nil
    required_field_isnil = false
    required_nil_fields = ""
  
    if projectname_field.nil? then
      required_field_isnil = true
      required_nil_fields += "ProjectName"
    else
      projectname = projectname_field.strip
    end
  
    if workspacename_field.nil? then
      required_field_isnil = true
      required_nil_fields += "WorkspaceName"
    else
      workspacename = workspacename_field.strip
    end
      
    if workspaceoid_field.nil? then
      required_field_isnil = true
      required_nil_fields += "WorkspaceOID"
    else
      workspaceoid = workspaceoid_field.strip
    end
  
    if required_field_isnil then
      @logger.warn "One or more required fields: "
      @logger.warn required_nil_fields
      @logger.warn "is missing! Skipping this row..."
      next
    end
    
    # Filter for possible nil values in optional fields
    if !parentname_field.nil? then
      parentname = parentname_field.strip
    else
      parentname = "N/A"
    end

    if !parentoid_field.nil? then
      parentoid = parentoid_field.strip
    else
      parentoid = "N/A"
    end

    if parentoid != "N/A" && parentname == "N/A" then
      @logger.warn "Rally Project: #{parentname} #{parentoid} mismatch"
      next
    end

    if !owneruid_field.nil? then
      owneruid = owneruid_field.strip
    else
      owneruid = "N/A"
    end   
   
    workspace_query.query_string = "((ObjectID = \"#{workspaceoid}\") AND (State = \"Open\"))"

    workspace_results = @rally.find(workspace_query)
    if workspace_results.total_result_count != 0 then
      if workspace_results.first().Name == workspacename then
        workspace = workspace_results.first()
      else
        @logger.error "Rally Workspace: #{workspacename} #{workspaceoid} mismatch"
        next
      end
    else
      @logger.error "Rally Workspace: #{workspaceoid} not found"
      next
    end
    
    if parentoid != "N/A" then
      project_query = RallyAPI::RallyQuery.new()
      project_query.type = :project
      project_query.fetch = "Name,State,ObjectID,Workspace,ObjectID"
      project_query.query_string = "((ObjectID = \"#{parentoid}\") AND (State = \"Open\"))"

      project_results = @rally.find(project_query)
        
      if project_results.total_result_count != 0 then
        if project_results.first().Name == parentname then
          if project_results.first().Workspace.ObjectID == workspace.ObjectID then
            parent = project_results.first()
          else
            @logger.error "Rally Project: #{parentname} Workspace: #{workspacename} mismatch"
            next
          end
        else
          @logger.error "Rally Project: #{parentname} #{parentoid} mismatch"
          next
        end
      else
        @logger.error "Rally Project: #{parentoid} not found"
        next
      end
    end

    if owneruid != "N/A" then
      single_user_query = RallyAPI::RallyQuery.new()
      single_user_query.type = :user
      single_user_query.fetch = "UserName,FirstName,LastName,DisplayName"
      single_user_query.page_size = 200 #optional - default is 200
      single_user_query.limit = 50000 #optional - default is 99999
      single_user_query.order = "UserName Asc"
      single_user_query.query_string = "(UserName = \"" + owneruid + "\")"
      
      single_user_results = @rally.find(single_user_query)
      
      if single_user_results.total_result_count != 0
        owner = single_user_results.first()
      else
        @logger.error "Rally User: #{owneruid} not found"
        next
      end
    end

    new_project_obj = {}
    new_project_obj["Name"] = projectname
    new_project_obj["State"] = "Open"
    new_project_obj["Workspace"] = workspace
    if parent !=nil
      new_project_obj["Parent"] = parent
    end
    if owner !=nil
      new_project_obj["Owner"] = owner
    end
    
    new_project = @rally.create(:project, new_project_obj)
    @logger.info "Created Rally Project: #{projectname}"
    
    if $permissions_mode == :none  
      next
    elsif $permissions_mode == :allusersviewers
      project_permission = $VIEWER
    elsif $permissions_mode == :alluserseditors
      project_permission = $EDITOR
    end  

    user_query = RallyAPI::RallyQuery.new()
    user_query.type = :user
    user_query.fetch = "UserName,FirstName,LastName,DisplayName"
    user_query.page_size = 200 #optional - default is 200
    user_query.limit = 50000 #optional - default is 99999
    user_query.order = "UserName Asc"
    user_query.query_string = "(Disabled = \"False\")"
    
    # Query for users
    @logger.info "Running initial query of users..."
    
    initial_user_query_results = @rally.find(user_query)
    n_users = initial_user_query_results.total_result_count

    @logger.info "Found a total of #{n_users} Enabled Users"
    
    user_query.fetch = $detail_fetch
    count = 1
    notify_increment = 10
    initial_user_query_results.each do | this_user_init |
      # Query Rally for single-user detailed info, including Permissions, Projects, and
      # Team Memberships
      user_query.query_string = "(UserName = \"" + this_user_init.UserName + "\")"
      detail_user_query_results = @rally.find(user_query)
    
      number_found = detail_user_query_results.total_result_count
      if number_found > 0 then
        this_user = detail_user_query_results.first
        
        # Summarize where we are in processing
        notify_remainder=count%notify_increment
        if notify_remainder==0 then @logger.info "Processed #{count} of #{n_users} Enabled Users" end
        count+=1
        
        if this_user.UserPermissions.include?("#{workspacename} #{$USER}") == true then
          @uh.update_project_permissions(new_project, this_user, project_permission, false)
        end
      end
    end
  end
  
  log_file.close
  
rescue => ex
  @logger.error ex
  @logger.error ex.backtrace
  @logger.error ex.message
end
