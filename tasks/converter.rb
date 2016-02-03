BOOTSTRAP_GEM_ROOT = Gem::Specification.find_by_name("bootstrap-sass").gem_dir
require "#{BOOTSTRAP_GEM_ROOT}/tasks/converter/less_conversion"
require 'rugged'

class Converter
  include Converter::LessConversion

  TEST_DIR = File.join('spec', 'html')
  TRANSFORMATIONS = [
    :replace_vars,
    :replace_file_imports,
    :replace_mixin_definitions,
    :replace_mixins,
    :replace_spin,
    # :replace_fadein,
    :replace_image_urls,
    :replace_escaping,
    :convert_less_ampersand,
    :deinterpolate_vararg_mixins,
    :replace_calculation_semantics,
    :remove_unnecessary_escaping
  ]
  TOP = <<-VAR.gsub(/^\s*/, '')
    // PatternFly SASS
    @import "patternfly/variables";
    @import "bootstrap/variables";
  VAR

  def initialize(options={})
    @repository  = options.fetch(:repository, 'patternfly/patternfly')
    @branch      = options.fetch(:branch, 'master')
    @destination = options.fetch(:destination, 'assets')
    @cache_path  = options.fetch(:cache_path, 'tmp')

    @source = File.join(@cache_path, 'repository')
  end

  def convert
    checkout_upstream
    copy_non_less
    process_stylesheets
    store_version
    FileUtils.rm_rf(@cache_path) # Clean up the repository & the cache
  end

  private

  def sass_read_mixins(file)
    file.scan(/@mixin\s+([^\(]+)\(/).flatten.uniq
  end

  def replace_mixins(file)
    mixins = shared_mixins + sass_read_mixins(file)
    super(file, mixins)
  end

  def remove_button_variant(file)
    replace_rules(file, /.button-variant(.*?)/) { |_, _| "" }
  end

  # SASS doesn't require escaping in calc()
  def remove_unnecessary_escaping(file)
    file.gsub(/calc\(\~\'([^\']+)\'\)/, 'calc(\1)')
  end

  # Override
  def replace_file_imports(less, target_path='')
    less.gsub!(
      %r{[@\$]import\s+(?:\(\w+\)\s+)?["|']([\w\-\./]+).less["|'];},
      "@import \"#{target_path}\\1\";"
    )
    less.gsub!(
      %r{[@\$]import\s+(?:\(\w+\)\s+)?["|']([\w\-\./]+).(css)["|'];},
      "@import \"#{target_path}\\1.\\2\";"
    )
    less
  end

  def insert_default_vars(file)
    file = super(file)
    file = replace_all(file, %r{"../img"}, '"../images"')
    file = replace_all(file, %r{(\$icon-font-path): (\s*)"(.*)" (!default);\n}, '')
    file = replace_all(file, %r{(\$fa-font-path): (\s*)"(.*)" (!default);\n}, '')
    file = replace_all(
      file,
      %r{(\$(font|img)-path):(\s*)"(.*)" (!default);},
      '\\1:\\3if($patternfly-sass-asset-helper, "patternfly", "\\4/patternfly") \\5;')
    ['$patternfly-sass-asset-helper: false !default;', file].join("\n")
  end

  def flatten_mixins(file)
    NESTED_MIXINS.inject(file) { |a, e| super(a, e.first, e.last) }
  end

  def fix_dropdown_toggle(file)
    replacestr = " {\\1}\n  .open & { &.dropdown-toggle {\\1} }"
    file = replace_all(file, /,\s*\.open\s+\.dropdown-toggle& \{([^\{\}]*?)\}/m, replacestr)
    replace_all(file, /,\s*\.open\s+\.dropdown-toggle& \{(.*?\{.*?\}.*?)\}/m, replacestr)
  end

  def fix_font_paths(file)
    replace_rules(file, /\s*@font-face/) { |rule| replace_asset_url(rule, :font) }
  end

  def fix_top_level(file)
    file = replace_all(file, %r{@import\s+"variables";}, "")
    file = replace_all(file, /@import "([^\.]{2})/, '@import "patternfly/\1')

    file = replace_all(file, "@import \"../components/bootstrap/less/bootstrap\";", fetch_bootstrap_top)
    file = replace_all(file, "@import \"../components/bootstrap/less/variables\";\n", '')
    file = replace_all(file, "@import \"../components/bootstrap/less/mixins\";\n", '')

    file = replace_all(file, "@import \"../components/font-awesome/less/variables\";\n", '')
    file = replace_all(file, '../components/font-awesome/less/font-awesome', 'font-awesome')
    file = replace_all(file, '../components/bootstrap-combobox/less/combobox', 'patternfly/bootstrap-combobox')
    file = replace_all(file, '../components/bootstrap-select/less/bootstrap-select', 'patternfly/bootstrap-select')
    file = replace_all(file, '../components/bootstrap-touchspin/dist/jquery.bootstrap-touchspin.css', 'patternfly/bootstrap-touchspin')
    file = replace_all(file, '../components/c3/c3.css', 'c3')
    file = replace_all(file, '../components/bootstrap-datepicker/less/datepicker3', 'patternfly/bootstrap-datepicker')

    sass_contrib('bootstrap-switch/src/less/bootstrap3/bootstrap-switch.less', 'bootstrap-switch.scss')
    file = replace_all(file, '../components/bootstrap-switch/src/less/bootstrap3/bootstrap-switch', 'patternfly/sass-contrib/bootstrap-switch')

    TOP + remove_comments_and_whitespace(file)
  end

  def sass_contrib(src, dst)
    base = 'assets/stylesheets/patternfly/sass-contrib'
    less = File.read(File.join('bower_components', src))
    sass = less_to_sass(nil, less)
    FileUtils.mkdir_p(base) unless File.exist?(base)
    File.open(File.join(base, dst), 'w') { |f| f.write(sass) }
  end

  def shared_mixins
    @shared_mixins ||= begin
      mixins = retrieve_files(File.join(@source, 'components', 'bootstrap', 'less', 'mixins'), /\.less$/)
      mixins.unshift File.join(@source, 'less', 'mixins.less')
      read_mixins(mixins.map { |f| File.read(f) }.join("\n"), :nested => NESTED_MIXINS)
    end
  end

  def fetch_bootstrap_top
    path = File.join(BOOTSTRAP_GEM_ROOT, 'assets', 'stylesheets', '_bootstrap.scss')
    file = replace_all(File.read(path), %r{@import\s+"bootstrap/variables";}, '')
    replace_all(file, %r{^(@import\s+"bootstrap/mixins";)}, "\\1\n@import \"patternfly/mixin_overrides\";")
  end

  def remove_comments_and_whitespace(input)
    input = replace_all(input, /\/\*.*?\*\//m, '')
    input = replace_all(input, /\s*\/\/.*$/, '')
    input.split("\n").reject { |line| line == "" }.join("\n").concat("\n")
  end

  def process_stylesheets
    save_to = File.join(@destination, 'stylesheets', 'patternfly')
    FileUtils.mkdir_p(save_to) unless File.exist?(save_to)

    patternfly_less_files.each do |path|
      file = File.basename(path)
      less = File.read(path)
      output = File.join(save_to, "_#{file.sub(/\.less$/, '.scss')}")
      File.open(output, 'w') do |f|
        f.write(less_to_sass(file, less))
      end
    end

    File.open(File.join(save_to, '..', '_patternfly.scss'), 'w') do |f|
      f.write(generate_top_level)
    end
  end

  def generate_top_level
    less_to_sass('patternfly.less', top_level_files.map { |f| File.read(f) }.join("\n"))
  end

  def copy_non_less
    copy_config.each do |asset|
      FileUtils.rm_rf(asset[:destination])
      retrieve_files(asset[:source], asset[:select], asset[:reject]).each do |f|
        copy_with_path(f, asset[:source], asset[:destination])
      end
    end
  end

  def retrieve_files(folder, select=/.*/, reject=nil)
    Dir["#{folder}/**/*"].reject { |f| File.directory?(f) || f !~ select || f =~ reject }
  end

  def copy_with_path(file, src, dst)
    dst = file.sub(/^#{src}/, dst)
    dir = File.dirname(dst)
    FileUtils.mkdir_p(dir) unless File.exist?(dir)
    FileUtils.cp(file, dst)
  end

  def checkout_upstream
    unless Dir.exist?(@source)
      repo = Rugged::Repository.clone_at("https://github.com/#{@repository}.git", @source)
    end
    repo ||= Rugged::Repository.new(@source)
    repo.checkout(@branch)
    @sha = repo.last_commit.oid

    FileUtils.cp( # Mixins correction
      File.join(@source, 'less', 'mixins.less'),
      File.join(@source, 'less', 'mixin_overrides.less')
    )
  end

  def replace_escaping(less)
    less = less.gsub(/~"([^"]+)"/, '#{\1}')
    less.gsub!(/\$\{([\w\-]+)\}/, '#{$\1}')
    less.gsub!(/\$\{([^}]+)\}/, '$\1')
    less.gsub(/(\W)e\(%\("?([^"]*)"?\)\)/, '\1\2')
  end

  def less_to_sass(file, input)
    transforms = TRANSFORMATIONS.dup
    case file
    when 'fonts.less', 'icons.less'
      transforms << :fix_font_paths
    when 'mixins.less',
      transforms << :flatten_mixins
      transforms << :fix_dropdown_toggle
    when 'mixin_overrides.less'
      transforms.unshift(:remove_button_variant)
      transforms << :flatten_mixins
    when 'variables.less'
      transforms.delete(:replace_spin)
      transforms << :insert_default_vars
    when 'patternfly.less'
      transforms.delete(:replace_spin)
      transforms << :fix_top_level
    when 'bootstrap-touchspin.less', 'spinner.less'
      transforms.delete(:replace_spin)
    end

    transforms.inject(input) { |a, e| send(e, a) }
  end

  def copy_config
    [
      {
        :source      => File.join(@source, 'dist', 'img'),
        :select      => /\.(png|gif|jpe?g|svg|ico)$/,
        :reject      => nil,
        :destination => File.join(@destination, 'images', 'patternfly')
      },
      {
        :source      => File.join(@source, 'dist', 'fonts'),
        :select      => /\.(eot|svg|ttf|woff2?)$/,
        :reject      => nil,
        :destination => File.join(@destination, 'fonts', 'patternfly')
      },
      {
        :source      => File.join(@source, 'dist', 'js'),
        :select      => /\.js$/,
        :reject      => nil,
        :destination => File.join(@destination, 'javascripts')
      },
      {
        :source      => File.join(@source, 'tests'),
        :select      => /.*/,
        :reject      => nil,
        :destination => TEST_DIR
      },
      {
        :source      => File.join(@source, 'dist', 'css'),
        :select      => /css/,
        :reject      => /styles(-additions)?(\.min)?\.css/,
        :destination => File.join(TEST_DIR, 'dist', 'css')
      }
    ]
  end

  def patternfly_less_files
    retrieve_files(File.join(@source, 'less'), /\.less$/, /lib|patternfly/)
  end

  def top_level_files
    retrieve_files(File.join(@source, 'less'), /patternfly(\-additions)?\.less$/)
  end

  def store_version
    path = 'lib/patternfly-sass/version.rb'
    content = File.read(path).sub(/PATTERNFLY_SHA\s*=\s*['"][\w]+['"]/, "PATTERNFLY_SHA = '#{@sha}'")
    File.open(path, 'w') { |f| f.write(content) }
  end

  def log_transform(*_opts)
  end

  def log_file_info(*_opts)
  end

  alias_method :bootstrap_less_files, :patternfly_less_files
end
