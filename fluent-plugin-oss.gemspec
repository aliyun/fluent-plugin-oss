$LOAD_PATH.push File.expand_path('lib', __dir__)

Gem::Specification.new do |gem|
  gem.name        = 'fluent-plugin-oss'
  gem.description = 'Aliyun OSS output plugin for Fluentd event collector'
  gem.license     = 'Apache-2.0'
  gem.homepage    = 'https://github.com/aliyun/fluent-plugin-oss'
  gem.summary     = gem.description
  gem.version     = File.read('VERSION').strip
  gem.authors     = ['Jinhu Wu']
  gem.email       = 'jinhu.wu.nju@gmail.com'
  gem.files       = `git ls-files`.split("\n")
  gem.test_files  = `git ls-files -- {test,spec,features}/*`.split("\n")
  gem.executables = `git ls-files -- bin/*`.split("\n").map do |f|
    File.basename(f)
  end
  gem.require_paths = ['lib']

  gem.add_dependency 'aliyun-sdk', ['0.7.0']
  gem.add_dependency 'fluentd', ['>= 0.14.22', '< 2']
  gem.add_development_dependency 'rake', '~> 0.9', '>= 0.9.2'
  gem.add_development_dependency 'test-unit', '~> 3.0', '>= 3.0.8'
  gem.add_development_dependency 'test-unit-rr', '~> 1.0', '>= 1.0.3'
end