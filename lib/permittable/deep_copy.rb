module Permittable
  # Copies a Hash/Array tree without recursing, as HashWithIndifferentAccess
  # (nested hashes) and deep_dup do not: each spends several stack frames a
  # level, and a Thread's stack (a Puma request thread, a job runner) holds
  # about 60 levels of one, a main thread's about 120 of deep_dup. A :json
  # value nested 62 deep, which JSON.parse accepts up to 100, overflowed a
  # thread, and a Contract takes any Hash, however deep a program built it.
  #
  # Every nested Hash becomes a HashWithIndifferentAccess and every Array a new
  # Array; ActionController::Parameters inside the tree are converted the way
  # to_unsafe_h converts the whole. With `dup_leaves:` every other value is
  # `dup`ed as deep_dup would (a request String the app may mutate must not
  # alias the caller's), otherwise it is shared.
  #
  # An empty container is attached to its parent before it is filled, so
  # HashWithIndifferentAccess's own deep conversion never has anything to
  # walk. Each pending entry carries its ancestors' ids, so a container that
  # holds itself (`h["self"] = h`) raises ArgumentError instead of being
  # copied for ever, which is what an iterative walk would otherwise do.
  module DeepCopy
    module_function

    def call(input, dup_leaves: false)
      root = ActiveSupport::HashWithIndifferentAccess.new
      pending = [[input, root, [input.object_id]]]
      until pending.empty?
        source, copy, ancestors = pending.pop
        if source.is_a?(Hash)
          source.each_pair { |key, value| copy[key] = copy_of(value, pending, ancestors, dup_leaves) }
        else
          source.each { |value| copy << copy_of(value, pending, ancestors, dup_leaves) }
        end
      end
      root
    end

    def copy_of(value, pending, ancestors, dup_leaves)
      value = value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
      copy = case value
             when Hash then ActiveSupport::HashWithIndifferentAccess.new
             when Array then []
             else return dup_leaves && value.duplicable? ? value.dup : value
             end
      raise ArgumentError, "#{LABEL}: input contains itself (a cyclic Hash or Array)" if ancestors.include?(value.object_id)

      pending << [value, copy, ancestors + [value.object_id]]
      copy
    end
  end
end
