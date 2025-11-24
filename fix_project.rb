require 'xcodeproj'

project_path = 'ios/Runner.xcodeproj'
project = Xcodeproj::Project.open(project_path)

target_name = 'NotificationServiceExtension'
target = project.targets.find { |t| t.name == target_name }

if target.nil?
  puts "Target #{target_name} not found!"
  exit 1
end

group_name = 'NotificationServiceExtension'
group = project.main_group.find_sub_group(group_name)

if group.nil?
  puts "Group #{group_name} not found!"
  # Try to find it recursively or create it?
  # Assuming it exists because the folder exists
  exit 1
end

file_name = 'NotificationService.swift'
# Check if file is already in group
existing_file = group.files.find { |f| f.path == file_name }

if existing_file
  puts "File reference already exists in group."
  # Check if it's in the target's build sources
  sources_build_phase = target.source_build_phase
  build_file = sources_build_phase.files.find { |f| f.file_ref == existing_file }
  
  if build_file
    puts "File is already in build sources."
  else
    puts "Adding file to build sources..."
    target.add_file_references([existing_file])
    project.save
    puts "Project saved."
  end
else
  puts "Adding file reference to group and target..."
  file_ref = group.new_file(file_name)
  target.add_file_references([file_ref])
  project.save
  puts "Project saved."
end
