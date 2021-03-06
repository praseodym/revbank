package RevBank::Plugins;
use strict;
use RevBank::Eval;
use RevBank::Plugin;
use Exporter;
our @EXPORT = qw(call_hooks load_plugins);

my @plugins;

sub _read_file {
    local (@ARGV) = @_;
    readline *ARGV;
}

sub call_hooks {
    my $hook = shift;
    my $method = "hook_$hook";
    for my $class (@plugins) {
         $class->$method(@_) if $class->can($method);
    }
};

sub register {
    call_hooks("register", $_) for @_;
    push @plugins, @_;
}

sub load {
    my @config = _read_file('revbank.plugins');
    chomp @config;
    s/#.*//g for @config;
    @config = map /(\S+)/, grep /\S/, @config;

    for my $name (@config) {
        my $fn = "plugins/$name";
        my $package = "RevBank::Plugin::$name";
        if (not -e $fn) {
            warn "$fn does not exist; skipping plugin.\n";
            next;
        }
        RevBank::Eval::clean_eval(qq[
            use strict;
            package $package;
            BEGIN { RevBank::Global->import; }
            our \@ISA = qw(RevBank::Plugin);
            our \%ATTR;
            sub MODIFY_CODE_ATTRIBUTES {
                my (\$class, \$sub, \@attrs) = \@_;
                \$ATTR{ \$sub } = "\@attrs";
                return;
            }
            sub FETCH_CODE_ATTRIBUTES {
                return \$ATTR{ +pop };
            }
            sub HELP {
                \$::HELP{ +shift } = +pop;
            }
            sub id { '$name' }
        ] . "\n#line 1 $fn\n" . join "", _read_file($fn));

        if ($@) {
            call_hooks("plugin_fail", $name, "Compile error: $@");
            next;
        }
        if (not $package->can("command")) {
            warn "Plugin $name does not have a 'command' method; skipping.\n";
            next;
        }

        register $package;
    }
}

sub new {
    return map $_->new, @plugins;
}

1;
__END__
=head1 NAME

RevBank::Plugins - Plugin mechanism for RevBank

=head1 DESCRIPTION

RevBank itself consists of a simple command line interface and a really brain
dead shopping cart. All transactions, even deposits and withdrawals, are
handled by plugins.

Plugins are defined in the C<revbank.plugins> file. Each plugin is a Perl
source file in the C<plugins> directory. Plugins are always iterated over in
the order they were defined in.

=head2 Methods

=head3 RevBank::Plugins::load

Reads the C<revbank.plugins> file and load the plugins.

=head3 RevBank::Plugins->new

Returns a B<list> of fresh plugin instances.

=head3 RevBank::Plugins::register($package)

Registers a plugin.

=head3 RevBank::Plugins::call_hooks($hook, @arguments)

Calls the given hook in each of the plugins. Non-standard hooks, called only
by plugins, SHOULD be prefixed with the name of the plugin, and an underscore.
For example, a plugin called C<cow> can call a hook called C<cow_moo> (which
calls the C<hook_cow_moo> methods).

There is no protection against infinite loops. Be careful!

=head1 WRITING PLUGINS

    *** CAUTION ***
    It is the responsibility of the PLUGINS to verify and normalize all
    input. Behaviour for bad input is UNDEFINED. Weird things could
    happen. Always use parse_user() and parse_amount() and test the
    outcome for defined()ness. Use the result of the parse_*() functions
    because that's canonicalised.

    Don't do this:
        $cart->add($u, $a, "Bad example");

    But do this:
        $u = parse_user($u)   or return REJECT, "$u: No such user.";
        $a = parse_amount($a) or return REJECT, "$a: Invalid amount.";
        $cart->add($u, $a, 'Good, except that $a is special in Perl :)');

There are two kinds of plugin methods: input methods and hooks. A plugin MUST
define one C<command> input method (but it MAY be a no-op), and can have any
number of hooks.

=head2 Input methods

Whenever a command is given in the 'outer' loop of revbank, the C<command>
method of the plugins is called until one of the plugins returns either
C<ACCEPT> or C<DONE>. An input method receives three arguments: the plugin
object, the shopping cart, and the given input string. The plugin object
(please call it C<$self>) is temporary but persists as long as your plugin
keeps control. It can be used as a scratchpad for carrying over values from
one method call to the next.

A command method MUST return with one of the following statements:

=over 10

=item return NEXT;

The plugin declines handling of the given command, and revbank should proceed
with the next one.

Input methods other than C<command> MUST NOT return C<NEXT>.

=item return REJECT, "Reason";

The plugin decides that the input should be rejected for the given reason.
RevBank will either query the user again, or (if there is any remaining input
in the buffer) abort the transaction to avoid confusion.

=item return ABORT, "Reason";

=item return ABORT;

The plugin decides that the transaction should be aborted.

=item return ACCEPT;

The plugin has finished processing the command. No other plugins will be called.

=item return "Prompt", $method;

The plugin requires arguments for the command, which will be taken from the
input buffer if extra input was given, or else, requested interactively.

The given method, which can be a reference or the name of the method, will be
called with the given input.

The literal input string C<abort> is a hard coded special case, and will
never reach the plugin's input methods.

=back

=head2 Hooks

Hooks are called at specific points in the processing flow, and MAY introspect
the shopping cart. They SHOULD NOT manipulate the shopping cart, but this option
is provided anyway, to allow for interesting hacks. If you do manipulate the
cart, re-evaluate your assumptions when upgrading!

Hooks SHOULD NOT prompt for input or execute programs that do so.

A plugin that exists only for its hooks, MUST still provide a C<command> method.
The suggested implementation for a no-op C<command> method is:

    sub command {
        return NEXT;
    }

Hooks are called as class methods. The return value is ignored. Hooks MUST NOT
interfere with the transaction flow (e.g. abort it).

The following hooks are available, with their respective arguments:

=over 10

=item hook_register $class, $plugin

Called when a new plugin is registered.

=item hook_abort $class, $cart

Called when a transaction is being aborted, right before the shopping cart is
emptied.

=item hook_prompt $class, $cart, $prompt

Called just before the user is prompted for input interactively. The prompt
MAY be altered by the plugin.

=item hook_input $class, $cart, $input, $split_input

Called when user input was given. C<$split_input> is a boolean that is true
if the input will be split on whitespace, rather than treated as a whole.
The input MAY be altered by the plugin.

=item hook_checkout $class, $cart, $user, $transaction_id

Called when the transaction is finalized.

=item hook_reject $class, $plugin, $reason, $abort

Called when input is rejected by a plugin. C<$abort> is true when the
transaction will be aborted because of the rejection.

=item hook_invalid_input $class, $cart, $word

Called when input was not recognised by any of the plugins.

=item hook_plugin_fail $class, $plugin, $error

Called when a plugin fails.

=item hook_user_created $class, $username

Called when a new user account was created.

=item hook_user_balance $class, $username, $old, $delta, $new, $transaction_id

Called when a user account is updated.

=back

Default messages can be silenced by overriding the hooks in
C<RevBank::Messages>. Such a hack might look like:

    undef &RevBank::Messages::hook_abort;

    sub hook_abort {
        print "This message is much better!\n"
    }

=head2 Utility functions

Several global utility functions are available. See L<RevBank::Global>

=head1 AUTHOR

Juerd Waalboer <#####@juerd.nl>

=head1 LICENSE

Pick your favorite OSI license.

