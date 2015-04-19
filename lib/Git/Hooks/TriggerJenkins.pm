## no critic (Modules::RequireVersionVar)
## no critic (Documentation)
package Git::Hooks::TriggerJenkins;

# ABSTRACT: Git::Hooks plugin to trigger build in Jenkins.

use 5.010;
use strict;
use warnings;
use English '-no_match_vars';
use Git::Hooks qw/:DEFAULT :utils/;
use Readonly;

my $PKG = __PACKAGE__;
(my $CFG = __PACKAGE__) =~ s/.*::/githooks./msx;

# CONSTANTS
Readonly::Scalar my $NR_PROJECT_PARAMETERS => 3;

#############
# Grok hook configuration, check it and set defaults.

sub _setup_config {
    my ($git) = @_;

    my $config = $git->get_config();

    $config->{lc $CFG} //= {};

    my $default = $config->{lc $CFG};

    $default->{require}    //= [1];
    $default->{unresolved} //= [1];

    return;
}

# Trigger Jenkins

sub _trigger_jenkins {
    my ($git) = @_;

    my $cache = $git->cache($PKG);

    # Connect to Jenkins if not yet connected
    if (!exists $cache->{jenkins}) {
        if (! eval { require Jenkins::API; }) {
            $git->error($PKG, 'Please install package Jenkins::API'
                    . ' to use the TriggerJenkins plugin', $EVAL_ERROR);
            return;
        }

        my %conn_opts;
        for my $option (qw/jenkinsurl jenkinsuser jenkinspass/) {
            $conn_opts{$option} = $git->get_config($CFG => $option)
                or $git->error($PKG, "missing $CFG.$option configuration attribute")
                    and return;
        }
        $conn_opts{base_url} =~ s/\/+$//msx; # trim trailing slashes from the URL

        my $jenkins = eval { Jenkins::API->new($conn_opts{base_url}, $conn_opts{api_user}, $conn_opts{api_pass}) };
        length $EVAL_ERROR
            and $git->error($PKG, "cannot connect to the Jenkins server at '$conn_opts{base_url}' as '$conn_opts{api_user}", $EVAL_ERROR)
                and return;

	my %projects;
        my @project_configs = $git->get_config($CFG => 'project');
	if (@project_configs) {
            foreach my $p_conf (@project_configs) {
                my ($p_name, $p_token, $p_opts)
                    = split qr/,/msx, $p_conf, $NR_PROJECT_PARAMETERS;
                $projects{$p_name} = {};
                if ($p_token) { $projects{$p_name}->{'token'} = $p_token; }
                if ($p_opts) { $projects{$p_name}->{'opts'} = $p_opts; }
            }
        }
        else {
            $git->error($PKG, 'No Jenkins project defined!');
            return;
	}

	foreach my $p_name (keys %projects) {
            $jenkins->trigger_build_with_parameters($p_name, $projects{$p_name});
        }

	$cache->{jenkins} = $jenkins;
    }

    return $cache->{jenkins};
}

sub check_patchset {
    my ($git, $opts) = @_;

    _setup_config($git);

    my $sha1   = $opts->{'--commit'};
    my $commit = $git->get_commit($sha1);

    # The --branch argument contains the branch short-name if it's in the
    # refs/heads/ namespace. But we need to always use the branch long-name,
    # so we change it here.
    my $branch = $opts->{'--branch'};
    $branch = "refs/heads/$branch"
        unless $branch =~ m:^refs/:;

    return check_commit_msg($git, $commit, $branch);
}

sub trigger_jenkins {
    my ($git) = @_;

    _setup_config($git);

    my $current_branch = $git->get_current_branch();
    if (!is_ref_enabled($current_branch, $git->get_config($CFG => 'ref'))) {
        return 1;
    }

    return _trigger_jenkins( $git, $current_branch);
}

sub check_ref {
    my ($git, $ref) = @_;

    if (!is_ref_enabled($ref, $git->get_config($CFG => 'ref'))) {
        return 1,
    }

    my $errors = 0;

    foreach my $commit ($git->get_affected_ref_commits($ref)) {
        trigger_jira($git, $commit)
            or ++$errors;
    }

    # Disconnect from Jenkins
    $git->clean_cache($PKG);

    return $errors == 0;
}

# This routine can act both as an update or a pre-receive hook.
sub check_affected_refs {
    my ($git) = @_;

    _setup_config($git);

    return 1 if im_admin($git);

    my $errors = 0;

    foreach my $ref ($git->get_affected_refs()) {
        check_ref($git, $ref)
            or ++$errors;
    }

    # Disconnect from Jenkins
    $git->clean_cache($PKG);

    return $errors == 0;
}

# Install hooks
POST_COMMIT       \&trigger_jira;
POST_RECEIVE      \&check_affected_refs;
REF_UPDATE       \&check_affected_refs;
PATCHSET_CREATED \&check_patchset;
DRAFT_PUBLISHED  \&check_patchset;
1;

__END__

=for Pod::Coverage check_codes check_commit_msg check_ref get_issue grok_msg_jiras

=head1 DESCRIPTION

This Git::Hooks plugin hooks itself to the hooks below to trigger a build
L<Continuous Integration|http://en.wikipedia.org/wiki/Continuous_integration>
service L<Jenkins|http://en.wikipedia.org/wiki/Jenkins_%28software%29>.
A build will normally include a pull from the repository and running all the
tests.

=over

=item * B<post-commit>

This hook is invoked after successful commit.

=item * B<post-receive>

This hook is invoked once in the remote repository during C<git push>.

=item * B<ref-update>

This hook is invoked when a push request is received by Gerrit Code
Review.

=item * B<patchset-created>

This hook is invoked when a push request is received by Gerrit Code
Review for a virtual branch (refs/for/*).

=back

To enable it you should add it to the githooks.plugin configuration
option:

    git config --add githooks.plugin TriggerJenkins

=head1 CONFIGURATION

The plugin is configured by the following git options.

=head2 githooks.triggerjenkins.ref REFSPEC

By default, Jenkins build is triggered every time a commit or push
was successful. If you want this to happen only when some refs
(usually some branch under
refs/heads/) is updated, you may specify them
with one or more instances of this option.

The refs can be specified as a complete ref name
(e.g. "refs/heads/master") or by a regular expression starting with a
caret (C<^>), which is kept as part of the regexp
(e.g. "^refs/heads/(master|fix)").

=head2 githooks.triggerjenkins.base-url URL

This option specifies the Jenkins server HTTP URL, used to construct the
C<Jenkins::API> object which is used to interact with your Jenkins
server. Please, see the Jenkins::API documentation to know about them. Required.

=head2 githooks.triggerjenkins.api-key USERNAME

This option specifies the Jenkins server username, used to construct the
C<Jenkins::API> object. Required.

=head2 githooks.triggerjenkins.api-pass PASSWORD

This option specifies the Jenkins server password, used to construct the
C<Jenkins::API> object. Required.

=head2 githooks.triggerjenkins.project KEY,TOKEN,JSON

The Jenkins project id, token and additional parameters which you want to build. If several, separate
by space (or comma?). Required.

# =head2 githooks.triggerjenkins.token KEY
#
# The Jenkins project id which you want to build. If several, separate
# by space. Required.
#
# =head2 githooks.triggerjenkins.build-parameters JSON_STRING
#
# Does the build require extra parameters? Specify them as a JSON string.
# If several, separate by space. 
#
=head1 EXPORTS

This module exports routines that can be used directly without
using all of Git::Hooks infrastructure.

TODO

=head2 check_affected_refs GIT

This is the routine used to implement the C<update> and the
C<pre-receive> hooks. It needs a C<Git::More> object.

=head2 check_message_file GIT, MSGFILE

This is the routine used to implement the C<commit-msg> hook. It needs
a C<Git::More> object and the name of a file containing the commit
message.

=head2 check_patchset GIT, HASH

This is the routine used to implement the C<patchset-created> Gerrit
hook. It needs a C<Git::More> object and the hash containing the
arguments passed to the hook by Gerrit.

=head1 CONTRIBUTORS

=over

=item * Mikko Koivunalho <mikkoi@cpan.org>

=back

