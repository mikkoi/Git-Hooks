#!/usr/bin/env perl

package Git::Hooks::CheckFileContent;
# ABSTRACT: Git::Hooks plugin to enforce file content issues.

use 5.010;
use utf8;
use strict;
use warnings;
use Git::Hooks qw/:DEFAULT :utils/;
use Data::Util qw(:check);
use Text::Glob qw/glob_to_regex/;
use Path::Tiny;
use Git::More::Message;
use List::MoreUtils qw/uniq/;
use Data::Dumper;

my $PKG = __PACKAGE__;
(my $CFG = __PACKAGE__) =~ s/.*::/githooks./;

# [githooks]
#     debug = 0
#     plugin = CheckFileContent
#     help-on-error = "Push failed. Please consult error messages."
# [githooks "checkfilecontent"]
#     id = perlpackage
#     perlpackage.recognize-by = filename || content
#     perlpackage.by-filename = *.p[m]
#     perlpackage.empty-lines-at-top = 1
#     perlpackage.empty-lines-at-bottom = 2
#     perlpackage.indent-character = tab
#     perlpackage.mixing-tab-and-space-allowed = 0
#     perlpackage.whitespace-before-eol-allowed = 0
#     perlpackage.indent-width = 4
#     perlpackage.indent-multiplier-check = 1
#     id = perlexe
#     perlexe.recognize-by = content && permissions
#     perlexe.by-content = "^#!/usr/bin/env perl$"
#     perlexe.by-permissions = x
#     perlexe.empty-lines-at-top = 0
#     perlexe.indent-character = space
#     id = perlexe2
#     perlexe2.recognize-by = permissions
#     perlexe2.by-permissions = x
#     perlexe2.indent-character = space

#############
# Grok hook configuration, check it and set defaults.

sub _setup_config {
    my ($git) = @_;

    my $config = $git->get_config();

    print Dumper($config);
    $config->{lc $CFG} //= {};

    my $default = $config->{lc $CFG};
    $default->{'title-required'}  //= [1];
    $default->{'title-max-width'} //= [50];
    $default->{'title-period'}    //= ['deny'];
    $default->{'body-max-width'}  //= [72];

    return;
}

##########

sub check_new_files { # TODO -> check_files!
    my ($git, $commit, @files) = @_;

    return 1 unless @files;     # No new file to check

    # First we construct a list of checks from the
    # githooks.checkfile.basename configuration. Each check in the list is a
    # pair containing a regex and a command specification.
    my @checks;
    foreach my $check ($git->get_config($CFG => 'name')) {
        my ($pattern, $command) = split / /, $check, 2;
        if ($pattern =~ m/^qr(.)(.*)\g{1}/) {
            $pattern = qr/$2/;
        } else {
            $pattern = glob_to_regex($pattern);
        }
        $command .= ' {}' unless $command =~ /\{\}/;
        push @checks, [$pattern => $command];
    }

    # Now we iterate through every new file and apply to them the matching
    # commands.
    my $errors = 0;

    foreach my $file (@files) {
        my $basename = path($file)->basename;
        foreach my $command (map {$_->[1]} grep {$basename =~ $_->[0]} @checks) {
            my $tmpfile = $git->blob($commit, $file)
                or ++$errors
                    and next;

            # interpolate filename in $command
            (my $cmd = $command) =~ s/\{\}/\'$tmpfile\'/g;

            # execute command and update $errors
            my $saved_output = redirect_output();
            my $exit = system $cmd;
            my $output = restore_output($saved_output);
            if ($exit != 0) {
                $command =~ s/\{\}/\'$file\'/g;
                my $message = do {
                    if ($exit == -1) {
                        "command '$command' could not be executed: $!";
                    } elsif ($exit & 127) {
                        sprintf("command '%s' was killed by signal %d, %s coredump",
                                $command, ($exit & 127), ($exit & 128) ? 'with' : 'without');
                    } else {
                        sprintf("command '%s' failed with exit code %d", $command, $exit >> 8);
                    }
                };

                # Replace any instance of the $tmpfile name in the output by
                # $file to avoid confounding the user.
                $output =~ s/\Q$tmpfile\E/$file/g;

                $git->error($PKG, $message, $output);
                ++$errors;
            } else {
                # FIXME: What we should do with eventual output from a
                # successful command?
            }
        }
    }

    return $errors == 0;
}

sub check_patterns {
    my ($git, $id, $msg) = @_;

    my $errors = 0;

    foreach my $match ($git->get_config($CFG => 'match')) {
        if ($match =~ s/^!\s*//) {
            $msg !~ /$match/m
                or $git->error($PKG, "commit $id log SHOULD NOT match '\Q$match\E'")
                    and ++$errors;
        } else {
            $msg =~ /$match/m
                or $git->error($PKG, "commit $id log SHOULD match '\Q$match\E'")
                    and ++$errors;
        }
    }

    return $errors == 0;
}

sub check_title {
    my ($git, $id, $title) = @_;

    $git->get_config($CFG => 'title-required')
        or return 1;

    defined $title
        or $git->error($PKG, "commit $id log needs a title line")
            and return 0;

    ($title =~ tr/\n/\n/) == 1
        or $git->error($PKG, "commit $id log title should have just one line")
            and return 0;

    my $errors = 0;

    if (my $max_width = $git->get_config($CFG => 'title-max-width')) {
        my $tlen = length($title) - 1; # discount the newline
        $tlen <= $max_width
            or $git->error($PKG, "commit $id log title should be at most $max_width characters wide, but it has $tlen")
                and ++$errors;
    }

    if (my $period = $git->get_config($CFG => 'title-period')) {
        if ($period eq 'deny') {
            $title !~ /\.$/
                or $git->error($PKG, "commit $id log title SHOULD NOT end in a period")
                    and ++$errors;
        } elsif ($period eq 'require') {
            $title =~ /\.$/
                or $git->error($PKG, "commit $id log title SHOULD end in a period")
                    and ++$errors;
        } elsif ($period ne 'allow') {
            $git->error($PKG, "invalid value for the $CFG.title-period option: '$period'")
                and ++$errors;
        }
    }

    return $errors == 0;
}

sub check_body {
    my ($git, $id, $body) = @_;

    return 1 unless defined $body && length $body;

    if (my $max_width = $git->get_config($CFG => 'body-max-width')) {
        my $toobig = $max_width + 1;
        if (my @biggies = ($body =~ /^(.{$toobig,})/gm)) {
            my $theseare = @biggies == 1 ? "this is" : "these are";
            $git->error($PKG,
                        "commit $id log body lines should be at most $max_width characters wide, but $theseare bigger",
                        join("\n", @biggies),
                    );
            return 0;
        }
    }

    return 1;
}

sub check_affected_refs {
    my ($git) = @_;

    return 1 if im_admin($git);

    my $errors = 0;

    foreach my $ref ($git->get_affected_refs()) {
        my ($old_commit, $new_commit) = $git->get_affected_ref_range($ref);
        check_new_files($git, $new_commit, $git->filter_files_in_range('AM', $old_commit, $new_commit))
            or ++$errors;
    }

    return $errors == 0;
}

sub check_commit {
    my ($git) = @_;

    return check_new_files($git, ':0', $git->filter_files_in_index('AM'));
}

sub check_patchset {
    my ($git, $opts) = @_;

    return 1 if im_admin($git);

    return check_new_files($git, $opts->{'--commit'}, $git->filter_files_in_commit('AM', $opts->{'--commit'}));
}

# Install hooks
PRE_COMMIT       \&check_commit;
UPDATE           \&check_affected_refs;
PRE_RECEIVE      \&check_affected_refs;
REF_UPDATE       \&check_affected_refs;
PATCHSET_CREATED \&check_patchset;
DRAFT_PUBLISHED  \&check_patchset;

1;

__END__
=for Pod::Coverage check_new_files check_affected_refs check_commit check_patchset

=head1 NAME

Git::Hooks::CheckFileContent - Git::Hooks plugin to enforce commit log policies.

=head1 DESCRIPTION

This Git::Hooks plugin hooks itself to the hooks below to enforce
policies on the commit log messages.

=over

=item * B<commit-msg>

This hook is invoked during the commit, to check if the commit log
message complies.

=item * B<update>

This hook is invoked multiple times in the remote repository during
C<git push>, once per branch being updated, to check if the commit log
messages of all commits being pushed comply.

=item * B<pre-receive>

This hook is invoked once in the remote repository during C<git push>,
to check if the commit log messages of all commits being pushed
comply.

=item * B<ref-update>

This hook is invoked when a push request is received by Gerrit Code
Review, to check if the commit log messages of all commits being
pushed comply.

=item * B<patchset-created>

This hook is invoked when a push request is received by Gerrit Code
Review for a virtual branch (refs/for/*), to check if the commit log
messages of all commits being pushed comply.

=back

Projects using Git, probably more than projects using any other
version control system, have a tradition of establishing policies on
the format of commit log messages. The REFERENCES section below lists
some of the most important.

This plugin allows one to enforce most of the established policies. The
default configuration already enforces the most common one.

To enable it you should add it to the githooks.plugin configuration
option:

    git config --add githooks.plugin CheckFileContent

=head1 CONFIGURATION

The plugin is configured by the following git options.

=head2 githooks.checklog.title-required [01]

The first line of a Git commit log message is usually called the
'title'. It must be separated by the rest of the message (it's 'body')
by one empty line. This option, which is 1 by default, makes the
plugin check if there is a proper title in the log message.

=head2 githooks.checklog.title-max-width N

This option specifies a limit to the width of the title's in
characters. It's 50 by default. If you set it to 0 the plugin imposes
no limit on the title's width.

=head2 githooks.checklog.title-period [deny|allow|require]

This option defines the policy regarding the title's ending in a
period ('.'). It can take three values:

=over

=item * B<deny>

This means that the title SHOULD NOT end in a period. This is the
default value of the option, as this is the most common policy.

=item * B<allow>

This means that the title MAY end in a period, i.e., it doesn't
matter.

=item * B<require>

This means that the title SHOULD end in a period.

=back

=head2 githooks.checklog.body-max-width N

This option specifies a limit to the width of the commit log message's
body lines, in characters. It's 72 by default. If you set it to 0 the
plugin imposes no limit on the body line's width.

=head2 githooks.checklog.match [!]REGEXP

This option may be specified more than once. It defines a list of
regular expressions that will be matched against the commit log
messages. If the '!' prefix is used, the log must not match the
REGEXP.

=head2 githooks.checklog.spelling [01]

This option makes the plugin spell check the commit log message using
C<Text::SpellChecker>. Any spelling error will cause the commit or push to
abort.

Note that C<Text::SpellChecker> isn't required to install
C<Git::Hooks>. So, you may see errors when you enable this
check. Please, refer to the module's own documentation to see how to
install it and its own dependencies (which are C<Text::Hunspell> or
C<Text::Aspell>).

=head2 githooks.checklog.spelling-lang ISOCODE

The Text::SpellChecker module uses defaults to infer which language it
must use to spell check the message. You can make it use a particular
language passing its ISO code to this option.

=head1 EXPORTS

This module exports the following routines that can be used directly
without using all of Git::Hooks infrastructure.

=head2 check_message_file GIT, MSGFILE

This is the routine used to implement the C<commit-msg> hook. It needs
a C<Git::More> object and the name of a file containing the commit
message.

=head2 check_affected_refs GIT

This is the routing used to implement the C<update> and the
C<pre-receive> hooks. It needs a C<Git::More> object.

=head2 check_patchset GIT, HASH

This is the routine used to implement the C<patchset-created> Gerrit
hook. It needs a C<Git::More> object and the hash containing the
arguments passed to the hook by Gerrit.

=head1 REFERENCES

=over

=item * B<git-commit(1) Manual Page>

This L<Git manual
page|<http://www.kernel.org/pub/software/scm/git/docs/git-commit.html>
has a section called DISCUSSION which discusses some common log
message policies.

=item * B<Linus Torvalds GitHub rant>

In L<this
note|https://github.com/torvalds/linux/pull/17#issuecomment-5659933>,
Linus says why he dislikes GitHub's pull request interface, mainly
because it doesn't allow him to enforce log message formatting
policies.

=item * B<MediaWiki Git/Commit message guidelines>

L<This
document|http://www.mediawiki.org/wiki/Git/Commit_message_guidelines>
defines MediaWiki's project commit log message guidelines.

=item * B<Proper Git Commit Messages and an Elegant Git History>

L<This is a good
discussion|http://ablogaboutcode.com/2011/03/23/proper-git-commit-messages-and-an-elegant-git-history/>
about commit log message formatting and the reasons behind them.

=item * B<GIT Commit Good Practice>

L<This document|https://wiki.openstack.org/wiki/GitCommitMessages>
defines the OpenStack's project commit policies.

=item * B<A Note About Git Commit Messages>

This L<blog
post|http://tbaggery.com/2008/04/19/a-note-about-git-commit-messages.html>
argues briefly and convincingly for the use of a particular format for Git
commit messages.

=item * B<Git Commit Messages: 50/72 Formatting>

This L<StackOverflow
question|http://stackoverflow.com/questions/2290016/git-commit-messages-50-72-formatting>
has a good discussion about the topic.

=back
