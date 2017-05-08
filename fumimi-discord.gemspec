lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require 'fumimi/version'

Gem::Specification.new do |spec|
  spec.name          = "fumimi-discord"
  spec.version       = Fumimi::VERSION
  spec.authors       = ["evazion"]
  spec.email         = ["noizave@gmail.com"]

  spec.summary       = "A Danbooru Discord bot."
  spec.homepage      = "https://github.com/evazion/fumimi-discord.git"
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0").reject do |f|
    f.match(%r{^(test|spec|features)/})
  end
  spec.bindir        = "bin"
  spec.executables   = %w[fumimi]
  spec.require_paths = ["lib"]

  spec.add_runtime_dependency "discordrb", "~> 3.2"
  spec.add_runtime_dependency "activesupport", "~> 5.1"
  spec.add_runtime_dependency "dotenv", "~> 2.2"

  spec.add_development_dependency "bundler", "~> 1.14"
  spec.add_development_dependency "rake", "~> 12.0"
  spec.add_development_dependency "pry", "~> 0.10"
  spec.add_development_dependency "pry-byebug", "~> 3.4"
  spec.add_development_dependency "minitest", "~> 5.0"
end
