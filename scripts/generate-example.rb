#!/usr/bin/env ruby
# Development helper only. Updates the checked-in project without replacing local signing or schemes.
gem 'xcodeproj', '>= 1.27.0'
require 'xcodeproj'

root = File.expand_path('..', __dir__)
example_root = File.join(root, 'Examples/DownloadLab')
project_path = File.join(example_root, 'DownloadLab.xcodeproj')
project = if File.exist?(File.join(project_path, 'project.pbxproj'))
            Xcodeproj::Project.open(project_path)
          else
            Xcodeproj::Project.new(project_path)
          end

app = project.targets.find { |target| target.name == 'DownloadLab' }
app ||= project.new_target(:application, 'DownloadLab', :ios, '17.0')
unit_tests = project.targets.find { |target| target.name == 'DownloadLabTests' }
unit_tests ||= project.new_target(:unit_test_bundle, 'DownloadLabTests', :ios, '17.0')
ui_tests = project.targets.find { |target| target.name == 'DownloadLabUITests' }
ui_tests ||= project.new_target(:ui_test_bundle, 'DownloadLabUITests', :ios, '17.0')

{
  app => Dir[File.join(example_root, 'Sources/*.swift')],
  unit_tests => [File.join(example_root, 'Tests/DeviceTests.swift')],
  ui_tests => Dir[File.join(example_root, 'UITests/*.swift')]
}.each do |target, paths|
  paths.each do |path|
    relative_path = path.delete_prefix(example_root + '/')
    reference = project.files.find { |file| file.path == relative_path }
    reference ||= project.main_group.new_file(relative_path)
    target.add_file_references([reference]) unless target.source_build_phase.files_references.include?(reference)
  end
end

package = project.root_object.package_references.find do |reference|
  reference.is_a?(Xcodeproj::Project::Object::XCLocalSwiftPackageReference) && reference.relative_path == '../..'
end
unless package
  package = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
  package.relative_path = '../..'
  project.root_object.package_references << package
end

[unit_tests, ui_tests].each do |target|
  target.add_dependency(app) unless target.dependencies.any? { |dependency| dependency.target == app }
  product = target.package_product_dependencies.find { |dependency| dependency.product_name == 'ConnectionRig' }
  unless product
    product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    product.package = package
    product.product_name = 'ConnectionRig'
    target.package_product_dependencies << product
    build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
    build_file.product_ref = product
    target.frameworks_build_phase.files << build_file
  end
end

[app, unit_tests, ui_tests].each do |target|
  target.build_configurations.each do |configuration|
    settings = configuration.build_settings
    settings['SWIFT_VERSION'] ||= '6.0'
    settings['PRODUCT_BUNDLE_IDENTIFIER'] ||= "org.connectionrig.#{target.name}"
    settings['GENERATE_INFOPLIST_FILE'] ||= 'NO'
    settings['INFOPLIST_FILE'] ||= target == app ? 'Info.plist' : 'Tests/Info.plist'
    settings['TARGETED_DEVICE_FAMILY'] ||= '1,2'
    settings['CODE_SIGN_STYLE'] ||= 'Automatic'
    settings['IPHONEOS_DEPLOYMENT_TARGET'] ||= '17.0'
    settings['SWIFT_STRICT_CONCURRENCY'] ||= 'complete'

    app_configuration = app.build_configurations.find { |candidate| candidate.name == configuration.name }
    team = app_configuration.build_settings['DEVELOPMENT_TEAM']
    settings['DEVELOPMENT_TEAM'] ||= team if team

    if target == unit_tests
      settings['TEST_HOST'] ||= '$(BUILT_PRODUCTS_DIR)/DownloadLab.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/DownloadLab'
      settings['BUNDLE_LOADER'] ||= '$(TEST_HOST)'
    elsif target == ui_tests
      settings['TEST_TARGET_NAME'] = app.name
    end
  end
end

# Resolve system frameworks through the active SDK, not the generator gem's old SDK version.
project.files.select { |file| file.path&.end_with?('Foundation.framework') }.each do |file|
  file.path = 'System/Library/Frameworks/Foundation.framework'
  file.source_tree = 'SDKROOT'
end
project.save

# Separate schemes prevent the single-session agent from receiving concurrent unit/UI scenarios.
# Existing schemes, environment variables and signing choices are preserved. Never copy secrets.
{ 'DownloadLab' => unit_tests, 'DownloadLabUITests' => ui_tests }.each do |name, target|
  scheme_path = File.join(project_path, 'xcshareddata/xcschemes', "#{name}.xcscheme")
  next if File.exist?(scheme_path)

  scheme = Xcodeproj::XCScheme.new
  scheme.add_build_target(app)
  scheme.add_test_target(target)
  scheme.set_launch_target(app)
  scheme.save_as(project_path, name, true)
end
