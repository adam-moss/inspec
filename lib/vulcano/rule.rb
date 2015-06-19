# encoding: utf-8
# copyright: 2015, Dominik Richter
# license: All rights reserved
require 'vulcano/base_rule'

module Vulcano
  class Rule < VulcanoBaseRule
    include Serverspec::Helper::Type
    extend Serverspec::Helper::Type
    include RSpec::Core::DSL

    # Override RSpec methods to add
    # IDs to each example group
    # TODO: remove this once IDs are in rspec-core
    def describe(sth, &block)
      @checks.push(['describe', [sth], block])
    end

    # redirect all regular method calls to the
    # core DSL (which is attached to the class)
    def method_missing(m, *a, &b)
      Vulcano::Rule.__send__(m, *a, &b)
    end

  end
end

module Vulcano::DSL
  def rule id, opts = {}, &block
    __register_rule Vulcano::Rule.new(id, opts, &block)
  end

  def skip_rule id
    __unregister_rule id
  end

  def require_rules id, &block
    ::Vulcano::DSL.load_spec_files_for_profile self, id, false, &block
  end

  def include_rules id, &block
    ::Vulcano::DSL.load_spec_files_for_profile self, id, true, &block
  end

  # Register a given rule with RSpec and
  # let it run. This happens after everything
  # else is merged in.
  def self.execute_rule r
    checks = r.instance_variable_get(:@checks)
    id = r.instance_variable_get(:@id)
    checks.each do |m,a,b|
      cres = ::Vulcano::Rule.__send__(m, *a, &b)
      if m == 'describe'
        set_rspec_ids(cres, id)
      end
    end
  end

  private

  # merge two rules completely; all defined
  # fields from src will be overwritten in dst
  def self.merge_rules dst, src
    VulcanoBaseRule::merge dst, src
  end

  # Attach an ID attribute to the
  # metadata of all examples
  # TODO: remove this once IDs are in rspec-core
  def self.set_rspec_ids(obj, id)
    obj.examples.each {|ex|
      ex.metadata[:id] = id
    }
    obj.children.each {|c|
      self.set_rspec_ids(c, id)
    }
  end

  def self.load_spec_file_for_profile profile_id, file, rule_registry
    raw = File::read(file)
    # TODO: error-handling

    ctx = Vulcano::ProfileContext.new(profile_id, rule_registry)
    ctx.instance_eval(raw, file, 1)
  end

  def self.load_spec_files_for_profile bind_context, profile_id, include_all, &block
    # get all spec files
    files = get_spec_files_for_profile profile_id
    # load all rules from spec files
    rule_registry = {}
    files.each do |file|
      load_spec_file_for_profile(profile_id, file, rule_registry)
    end

    # interpret the block and create a set of rules from it
    block_registry = {}
    if block_given?
      ctx = Vulcano::ProfileContext.new(profile_id, block_registry)
      ctx.instance_eval(&block)
    end

    # if all rules are not included, select only the ones
    # that were defined in the block
    unless include_all
      remove = rule_registry.keys - block_registry.keys
      remove.each{|key| rule_registry.delete(key)}
    end

    # merge the rules in the block_registry (adjustments) with
    # the rules in the rule_registry (included)
    block_registry.each do |id,r|
      org = rule_registry[id]
      if org.nil?
        # TODO: print error because we write alter a rule that doesn't exist
      elsif r.nil?
        rule_registry.delete(id)
      else
        merge_rules(org, r)
      end
    end

    # finally register all combined rules
    rule_registry.each do |id, rule|
      bind_context.__register_rule rule
    end
  end

  def self.get_spec_files_for_profile id
    base_path = '/etc/vulcanosec/tests'
    path = File.join( base_path, id )
    # find all files to be included
    files = []
    if File::directory? path
      # include all library paths, if they exist
      libdir = File::join(path, 'lib')
      if File::directory? libdir and !$LOAD_PATH.include?(libdir)
        $LOAD_PATH.unshift(libdir)
      end
      files = Dir[File.join(path, 'spec','*_spec.rb')]
    end
    return files
  end

end

module Vulcano
  class ProfileContext

    include Vulcano::DSL
    def initialize profile_id, profile_registry
      @profile_id = profile_id
      @rules = profile_registry
    end

    def __unregister_rule id
      full_id = "#{@profile_id}/#{id}"
      @rules[full_id] = nil
    end

    def __register_rule r
      # get the full ID
      full_id = VulcanoBaseRule::full_id(r, @profile_id)
      if full_id.nil?
        # TODO error
        return
      end
      # add the rule to the registry
      existing = @rules[full_id]
      if existing.nil?
        @rules[full_id] = r
      else
        VulcanoBaseRule::merge(existing, r)
      end
    end

  end
end

module Vulcano::GlobalDSL
  def __register_rule r
    ::Vulcano::DSL.execute_rule(r)
  end
  def __unregister_rule id
  end
end

module Vulcano::DSLHelper
  def self.bind_dsl(scope)
    (class << scope; self; end).class_exec do
      include Vulcano::DSL
      include Vulcano::GlobalDSL
    end
  end
end

::Vulcano::DSLHelper.bind_dsl(self)
