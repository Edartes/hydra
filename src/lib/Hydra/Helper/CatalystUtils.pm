package Hydra::Helper::CatalystUtils;

use utf8;
use strict;
use Exporter;
use Readonly;
use Nix::Store;
use Hydra::Helper::Nix;

our @ISA = qw(Exporter);
our @EXPORT = qw(
    getBuild getPreviousBuild getNextBuild getPreviousSuccessfulBuild
    searchBuildsAndEvalsForJobset
    error notFound gone accessDenied
    forceLogin requireUser requireProjectOwner requireAdmin requirePost isAdmin isProjectOwner
    trim
    getLatestFinishedEval getFirstEval
    paramToList
    backToReferer
    $pathCompRE $relPathRE $relNameRE $projectNameRE $jobsetNameRE $jobNameRE $systemRE $userNameRE $inputNameRE
    @buildListColumns
    parseJobsetName
    showJobName
    showStatus
    getResponsibleAuthors
    setCacheHeaders
    approxTableSize
    requireLocalStore
    dbh
);


# Columns from the Builds table needed to render build lists.
Readonly our @buildListColumns => ('id', 'finished', 'timestamp', 'stop_time', 'project', 'jobset', 'job', 'nix_name', 'system', 'build_status', 'release_name');


sub getBuild {
    my ($c, $id) = @_;
    my $build = $c->model('DB::Builds')->find($id);
    return $build;
}


sub getPreviousBuild {
    my ($build) = @_;
    return undef if !defined $build;
    return $build->job->builds->search(
      { finished => 1
      , system => $build->system
      , 'me.id' =>  { '<' => $build->id }
        , -not => { build_status => { -in => [4, 3]} }
      }, { rows => 1, order_by => "me.id DESC" })->single;
}


sub getNextBuild {
    my ($c, $build) = @_;
    return undef if !defined $build;

    (my $nextBuild) = $c->model('DB::Builds')->search(
      { finished => 1
      , system => $build->system
      , project => $build->project->name
      , jobset => $build->jobset->name
      , job => $build->job->name
      , 'me.id' =>  { '>' => $build->id }
      }, {rows => 1, order_by => "me.id ASC"});

    return $nextBuild;
}


sub getPreviousSuccessfulBuild {
    my ($c, $build) = @_;
    return undef if !defined $build;

    (my $prevBuild) = $c->model('DB::Builds')->search(
      { finished => 1
      , system => $build->system
      , project => $build->project->name
      , jobset => $build->jobset->name
      , job => $build->job->name
      , build_status => 0
      , 'me.id' =>  { '<' => $build->id }
      }, {rows => 1, order_by => "me.id DESC"});

    return $prevBuild;
}


sub searchBuildsAndEvalsForJobset {
    my ($jobset, $condition, $maxBuilds) = @_;

    my @evals = $jobset->jobset_evals->search(
        { has_new_builds => 1},
        { order_by => "id desc",
        rows => 20
    });

    my $evals = {};
    my %builds;
    my $nrBuilds = 0;

    foreach my $eval (@evals) {
        my @allBuilds = $eval->builds->search(
            $condition,
            { columns => ['id', 'job', 'finished', 'build_status'] }
        );

        foreach my $b (@allBuilds) {
            my $jobName = $b->get_column('job');

            $evals->{$eval->id}->{timestamp} = $eval->timestamp;
            $evals->{$eval->id}->{builds}->{$jobName} = {
                id => $b->id,
                finished => $b->finished,
                build_status => $b->build_status
            };
            $builds{$jobName} = 1;
            $nrBuilds++;
        }
        last if $maxBuilds && $nrBuilds >= $maxBuilds;
    }

    return ($evals, \%builds);
}


sub error {
    my ($c, $msg, $status) = @_;
    $c->response->status($status) if defined $status;
    $c->error($msg);
    $c->detach; # doesn't return
}


sub notFound {
    my ($c, $msg) = @_;
    error($c, $msg, 404);
}


sub gone {
    my ($c, $msg) = @_;
    error($c, $msg, 410);
}


sub accessDenied {
    my ($c, $msg) = @_;
    error($c, $msg, 403);
}


sub backToReferer {
    my ($c) = @_;
    $c->response->redirect($c->session->{referer} || $c->uri_for('/'));
    $c->session->{referer} = undef;
    $c->detach;
}


sub forceLogin {
    my ($c) = @_;
    $c->session->{referer} = $c->request->uri;
    accessDenied($c, "This page requires you to sign in.");
}


sub requireUser {
    my ($c) = @_;
    forceLogin($c) if !$c->user_exists;
}


sub isProjectOwner {
    my ($c, $project) = @_;
    return
        $c->user_exists &&
        (isAdmin($c) ||
         $c->user->username eq $project->owner->username ||
         defined $c->model('DB::ProjectMembers')->find({ project => $project, username => $c->user->username }));
}


sub requireProjectOwner {
    my ($c, $project) = @_;
    requireUser($c);
    accessDenied($c, "Only the project members or administrators can perform this operation.")
        unless isProjectOwner($c, $project);
}


sub isAdmin {
    my ($c) = @_;
    return $c->user_exists && $c->check_user_roles('admin');
}


sub requireAdmin {
    my ($c) = @_;
    requireUser($c);
    accessDenied($c, "Only administrators can perform this operation.")
        unless isAdmin($c);
}


sub requirePost {
    my ($c) = @_;
    error($c, "Request must be POSTed.") if $c->request->method ne "POST";
}


sub trim {
    my $s = shift;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}


sub getLatestFinishedEval {
    my ($jobset) = @_;
    my ($eval) = $jobset->jobset_evals->search(
        { has_new_builds => 1 },
        { order_by => "id DESC", rows => 1
        , where => \ "not exists (select 1 from jobset_eval_members m join builds b on m.build = b.id where m.eval = me.id and b.finished = 0)"
        });
    return $eval;
}


sub getFirstEval {
    my ($build) = @_;
    return $build->jobset_evals->search(
        { has_new_builds => 1},
        { rows => 1, order_by => ["id"] })->single;
}


# Catalyst request parameters can be an array or a scalar or
# undefined, making them annoying to handle.  So this utility function
# always returns a request parameter as a list.
sub paramToList {
    my ($c, $name) = @_;
    my $x = $c->stash->{params}->{$name};
    return () unless defined $x;
    return @$x if ref($x) eq 'ARRAY';
    return ($x);
}


# Security checking of filenames.
Readonly our $pathCompRE    => "(?:[A-Za-z0-9-\+\._\$][A-Za-z0-9-\+\._\$:]*)";
Readonly our $relPathRE     => "(?:$pathCompRE(?:/$pathCompRE)*)";
Readonly our $relNameRE     => "(?:[A-Za-z0-9-_][A-Za-z0-9-\._]*)";
Readonly our $attrNameRE    => "(?:[A-Za-z_][A-Za-z0-9-_]*)";
Readonly our $projectNameRE => "(?:[A-Za-z_][A-Za-z0-9-_]*)";
Readonly our $jobsetNameRE  => "(?:[A-Za-z_][A-Za-z0-9-_\.]*)";
Readonly our $jobNameRE     => "(?:$attrNameRE(?:\\.$attrNameRE)*)";
Readonly our $systemRE      => "(?:[a-z0-9_]+-[a-z0-9_]+)";
Readonly our $userNameRE    => "(?:[a-z][a-z0-9_\.]*)";
Readonly our $inputNameRE   => "(?:[A-Za-z_][A-Za-z0-9-_]*)";


sub parseJobsetName {
    my ($s) = @_;
    $s =~ /^($projectNameRE):(\.?$jobsetNameRE)$/ or die "invalid jobset specifier ‘$s’\n";
    return ($1, $2);
}


sub showJobName {
    my ($build) = @_;
    return $build->project->name . ":" . $build->jobset->name . ":" . $build->job->name;
}


sub showStatus {
    my ($build) = @_;

    my $status = "Failed";
    if ($build->build_status == 0) { $status = "Success"; }
    elsif ($build->build_status == 1) { $status = "Failed"; }
    elsif ($build->build_status == 2) { $status = "Dependency failed"; }
    elsif ($build->build_status == 4) { $status = "Cancelled"; }
    elsif ($build->build_status == 6) { $status = "Failed with output"; }

    return $status;
}


# Determine who broke/fixed the build.
sub getResponsibleAuthors {
    my ($build, $plugins) = @_;

    my $prevBuild = getPreviousBuild($build);
    return ({}, 0, []) unless $prevBuild;

    my $nrCommits = 0;
    my %authors;
    my @emailable_authors;

    my $prevEval = getFirstEval($prevBuild);
    my $eval = getFirstEval($build);

    foreach my $curInput ($eval->jobset_eval_inputs) {
        next unless ($curInput->type eq "git" || $curInput->type eq "hg");
        my $prevInput = $prevEval->jobset_eval_inputs->find({ name => $curInput->name });
        next unless defined $prevInput;

        next if $curInput->type ne $prevInput->type;
        next if $curInput->uri ne $prevInput->uri;
        next if $curInput->revision eq $prevInput->revision;

        my @commits;
        foreach my $plugin (@{$plugins}) {
            push @commits, @{$plugin->getCommits($curInput->type, $curInput->uri, $prevInput->revision, $curInput->revision)};
        }

        foreach my $commit (@commits) {
            #print STDERR "$commit->{revision} by $commit->{author}\n";
            $authors{$commit->{author}} = $commit->{email};
            my $inputSpec = $build->jobset->jobset_inputs->find({ name => $curInput->name });
            push @emailable_authors, $commit->{email} if $inputSpec && $inputSpec->email_responsible;
            $nrCommits++;
        }
    }

    return (\%authors, $nrCommits, \@emailable_authors);
}


# Set HTTP headers for the Nix binary cache.
sub setCacheHeaders {
    my ($c, $expiration) = @_;
    $c->response->headers->expires(time + $expiration);
    delete $c->response->cookies->{hydra_session};
}


sub approxTableSize {
    my ($c, $name) = @_;
    return $c->model('DB')->schema->storage->dbh->selectrow_hashref(
        "select reltuples::int from pg_class where relname = lower(?)", { }, $name)->{"reltuples"};
}


sub requireLocalStore {
    my ($c) = @_;
    notFound($c, "Nix channels are not supported by this Hydra server.")
        if ($c->config->{store_mode} // "direct") ne "direct";
}


sub dbh {
    my ($c) = @_;
    return $c->model('DB')->schema->storage->dbh;
}


1;
