source 'https://rubygems.org'

gemspec

# No Gemfile.lock is committed — this is a library, not an application — and no
# version is pinned here. The gemspec's `spree_core >= 5.5, < 6.0` range IS the
# compatibility claim, so CI resolves it fresh and must exercise that range
# rather than a single point in it.
#
# CI sets SPREE_CORE_VERSION per matrix leg: 5.5.1 (what the consuming
# application runs) and the latest 5.6.x (which emits a `preorder` field 5.5
# does not — the reason the schema declares that field optional).
if (spree_core_version = ENV['SPREE_CORE_VERSION'])
  gem 'spree_core', spree_core_version
end
