@tool
class_name NetCommand extends Resource

# Base class for per-tick commands (inputs). Subclass with @export var fields.
# The framework treats these as opaque field bundles authored by the user; the
# scene's predicted controller gathers them each tick and the simulator
# consumes them.
