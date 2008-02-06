require "pathname"
require "core/project"
require "java/artifact"
require 'stringio'
require 'rexml/document'

module Buildr
  module Idea7x #:nodoc:

    include Extension

    CLASSIFIER = "-7x"
    IML_SUFFIX = CLASSIFIER + ".iml"
    IPR_TEMPLATE = "idea7x.ipr.template"
    MODULE_DIR = "$MODULE_DIR$"
    FILE_PATH_PREFIX = "file://"
    MODULE_DIR_URL = FILE_PATH_PREFIX + MODULE_DIR
    PROJECT_DIR = "$PROJECT_DIR$"
    PROJECT_DIR_URL = FILE_PATH_PREFIX + PROJECT_DIR

    first_time do
      # Global task "idea" generates artifacts for all projects.
      desc "Generate Idea 7.x artifacts for all projects"
      Project.local_task "idea7x"=>"artifacts"
    end

    before_define do |project|
      project.recursive_task("idea7x")
    end

    after_define do |project|
      idea7x = project.task("idea7x")

      # We need paths relative to the top project's base directory.
      root_path = lambda { |p| f = lambda { |p| p.parent ? f[p.parent] : p.base_dir }; f[p] }[project]

      sources = Buildr.build_files.map { |file| File.expand_path(file) }.select { |file| File.exist?(file) }
      sources << File.expand_path(Rake.application.rakefile, root_path) if Rake.application.rakefile

      # Find a path relative to the project's root directory.
      relative = lambda do |path|
        Pathname.new(path.to_s).relative_path_from(Pathname.new(project.path_to)).to_s
      end

      m2repo = Buildr::Repositories.instance.local
      excludes = [ '**/.svn/', '**/CVS/' ].join('|')

      # Only for projects that are packageable.
      task_name = project.path_to("#{project.name.gsub(':', '-')}#{IML_SUFFIX}")
      idea7x.enhance [ file(task_name) ]

      # The only thing we need to look for is a change in the Buildfile.
      file(task_name=>sources) do |task|
        puts "Writing #{task.name}" if verbose

        # Note: Use the test classpath since Eclipse compiles both "main" and "test" classes using the same classpath
        deps = project.test.compile.dependencies.map(&:to_s) - [ project.compile.target.to_s ]

        # Convert classpath elements into applicable Project objects
        deps.collect! { |path| Buildr.projects.detect { |prj| prj.packages.detect { |pkg| pkg.to_s == path } } || path }

        # project_libs: artifacts created by other projects
        project_libs, others = deps.partition { |path| path.is_a?(Project) }

        # Separate artifacts from Maven2 repository
        m2_libs, others = others.partition { |path| path.to_s.index(m2repo) == 0 }

        # Generated: classpath elements in the project are assumed to be generated
        generated, libs = others.partition { |path| path.to_s.index(project.path_to.to_s) == 0 }

        # Project type is going to be the first package type
        if package = project.packages.first
          File.open(task.name, "w") do |file|
            xml = Builder::XmlMarkup.new(:target=>file, :indent=>2)
            xml.module(:version=>"4", :relativePaths=>"true", :type=>"JAVA_MODULE") do
              xml.component(:name=>"NewModuleRootManager", "inherit-compiler-output"=>"false") do

                Buildr::Idea7x.generate_compile_output(project, xml, relative)

                Buildr::Idea7x.generate_content(project, xml, generated, relative)

                Buildr::Idea7x.generate_order_entries(project_libs, xml)

                ext_libs = libs.map {|path| "#{MODULE_DIR}/#{path.to_s}" } + m2_libs.map { |path| path.to_s.sub(m2repo, "$M2_REPO$") }
                Buildr::Idea7x.generate_module_libs(xml, ext_libs)

                xml.orderEntryProperties
              end
            end
          end
        end
      end

      # Root project aggregates all the subprojects.
      if project.parent == nil
        Buildr::Idea7x.generate_ipr(project, idea7x, sources)
      end

    end # after_define

    private

    def self.generate_order_entries(project_libs, xml)
      xml.orderEntry :type=>"sourceFolder", :forTests=>"false"
      xml.orderEntry :type=>"inheritedJdk"

      # Classpath elements from other projects
      project_libs.map(&:id).sort.uniq.each do |project_id|
        xml.orderEntry :type=>'module', "module-name"=>"#{project_id}#{CLASSIFIER}"
      end
    end

    def self.generate_compile_output(project, xml, relative)
      xml.output(:url=>"#{MODULE_DIR_URL}/#{relative[project.compile.target.to_s]}") if project.has_compile_sources
      xml.output-test(:url=>"#{MODULE_DIR_URL}/#{relative[project.test.compile.target.to_s]}") if project.has_test_sources
    end

    def self.generate_content(project, xml, generated, relative)
      xml.content(:url=>"#{MODULE_DIR_URL}") do
        if project.has_compile_sources
          srcs = project.compile.sources.map { |src| relative[src.to_s] } + generated.map { |src| relative[src.to_s] }
          srcs.sort.uniq.each do |path|
            xml.sourceFolder :url=>"#{MODULE_DIR_URL}/#{path}", :isTestSource=>"false"
          end

          test_sources = project.test.compile.sources.map { |src| relative[src.to_s] }
          test_sources.each do |paths|
            paths.sort.uniq.each do |path|
              xml.sourceFolder :url=>"#{MODULE_DIR_URL}/#{path}", :isTestSource=>"true"
            end
          end
        end
        [project.resources=>false, project.test.resources=>true].each do |resources, test|
          resources.each do |path|
            path[0].sources.each do |srcpath|
              xml.sourceFolder :url=>"#{FILE_PATH_PREFIX}#{srcpath}", :isTestSource=>path[1].to_s
            end
          end
        end
        xml.excludeFolder :url=>"#{MODULE_DIR_URL}/#{relative[project.compile.target.to_s]}" if project.has_compile_sources
      end
    end

    def self.generate_module_libs(xml, ext_libs)
      ext_libs.each do |path|
        xml.orderEntry :type=>"module-library" do
          xml.library do
            xml.CLASSES do
              xml.root :url=>"jar://#{path}!/"
            end
            xml.JAVADOC
            xml.SOURCES
          end
        end
      end
    end

    def self.generate_ipr(project, idea7x, sources)
      task_name = project.path_to("#{project.name.gsub(':', '-')}-7x.ipr")
      idea7x.enhance [ file(task_name) ]
      file(task_name=>sources) do |task|
        puts "Writing #{task.name}" if verbose

        # Generating just the little stanza that chanages from one project to another
        partial = StringIO.new
        xml = Builder::XmlMarkup.new(:target=>partial, :indent=>2)
        xml.component(:name=>"ProjectModuleManager") do
          xml.modules do
            project.projects.each do |subp|
              module_name = subp.name.gsub(":", "-")
              module_path = subp.name.split(":"); module_path.shift
              module_path = module_path.join(File::SEPARATOR)
              path = "#{module_path}/#{module_name}#{IML_SUFFIX}"
              xml.module :fileurl=>"#{PROJECT_DIR_URL}/#{path}", :filepath=>"#{PROJECT_DIR}/#{path}"
            end
            if package = project.packages.first
              xml.module :fileurl=>"#{PROJECT_DIR_URL}/#{project.name}#{IML_SUFFIX}", :filepath=>"#{PROJECT_DIR}/#{project.name}#{IML_SUFFIX}"
            end
          end
        end

        # Loading the whole fairly constant crap
        template_xml = REXML::Document.new(File.open(File.join(File.dirname(__FILE__), IPR_TEMPLATE)))
        include_xml = REXML::Document.new(partial.string)
        template_xml.root.add_element(include_xml.root)
        template_xml.write(File.new(task.name, "w"))
      end
    end


  end  # module Idea7x
end # module Buildr

class Buildr::Project

  include Buildr::Idea7x

  def has_compile_sources
    self.compile.target.to_s.size > 0
  end

  def has_test_sources
    self.test.compile.target.to_s.size > 0
  end
end