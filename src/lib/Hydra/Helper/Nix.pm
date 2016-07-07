package Hydra::Helper::Nix;

use strict;
use Exporter;
use File::Path;
use File::Basename;
use Config::General;
use Hydra::Helper::CatalystUtils;
use Hydra::Model::DB;
use Nix::Store;
use Encode;
use Sys::Hostname::Long;

our @ISA = qw(Exporter);
our @EXPORT = qw(
    getHydraHome getHydraConfig getBaseUrl txn_do
    getSCMCacheDir
    registerRoot getGCRootsDir gcRootFor
    jobsetOverview jobsetOverview_
    removeAsciiEscapes getDrvLogPath findLog logContents
    getMainOutput
    getEvals getMachines
    pathIsInsidePrefix
    captureStdoutStderr run grab
    getTotalShares
    cancelBuilds restartBuilds);


sub getHydraHome {
    my $dir = $ENV{"HYDRA_HOME"} or die "The HYDRA_HOME directory does not exist!\n";
    return $dir;
}


my $hydraConfig;

sub getHydraConfig {
    return $hydraConfig if defined $hydraConfig;
    my $conf = $ENV{"HYDRA_CONFIG"} || (Hydra::Model::DB::getHydraPath . "/hydra.conf");
    if (-f $conf) {
        my %h = new Config::General($conf)->getall;
        $hydraConfig = \%h;
    } else {
        $hydraConfig = {};
    }
    return $hydraConfig;
}


sub getBaseUrl {
    my ($config) = @_;
    return $config->{'base_uri'} // "http://" . hostname_long . ":3000";
}


# Awful hack to handle timeouts in SQLite: just retry the transaction.
# DBD::SQLite *has* a 30 second retry window, but apparently it
# doesn't work.
# TODO: Remove this, because we no longer support SQLite!
sub txn_do {
    my ($db, $coderef) = @_;
    my $res;
    while (1) {
        eval {
            $res = $db->txn_do($coderef);
        };
        return $res if !$@;
        die $@ unless $@ =~ "database is locked";
    }
}


sub getSCMCacheDir {
    return Hydra::Model::DB::getHydraPath . "/scm" ;
}


sub getGCRootsDir {
    my $config = getHydraConfig();
    my $dir = $config->{gc_roots_dir};
    unless (defined $dir) {
        die unless defined $ENV{LOGNAME};
        $dir = ($ENV{NIX_STATE_DIR} || "/nix/var/nix" ) . "/gcroots/per-user/$ENV{LOGNAME}/hydra-roots";
    }
    mkpath $dir if !-e $dir;
    return $dir;
}


sub gcRootFor {
    my ($path) = @_;
    return getGCRootsDir . "/" . basename $path;
}


sub registerRoot {
    my ($path) = @_;
    my $link = gcRootFor $path;
    return if -e $link;
    open ROOT, ">$link" or die "cannot create GC root `$link' to `$path'";
    close ROOT;
}


sub attrsToSQL {
    my ($attrs, $id) = @_;
    my @attrs = split / /, $attrs;

    my $query = "1 = 1";

    foreach my $attr (@attrs) {
        $attr =~ /^([\w-]+)=([\w-]*)$/ or die "invalid attribute in view: $attr";
        my $name = $1;
        my $value = $2;
        # !!! Yes, this is horribly injection-prone... (though
        # name/value are filtered above).  Should use SQL::Abstract,
        # but it can't deal with subqueries.  At least we should use
        # placeholders.
        $query .= " and exists (select 1 from build_inputs where build = $id and name = '$name' and value = '$value')";
    }

    return $query;
}


sub jobsetOverview_ {
    my ($c, $jobsets) = @_;
    return $jobsets->search({},
        { order_by => "name"
        , "+select" =>
          [ "(select count(*) from builds as a where a.finished = 0 and me.project = a.project and me.name = a.jobset and a.is_current = 1)"
          , "(select count(*) from builds as a where a.finished = 1 and me.project = a.project and me.name = a.jobset and build_status <> 0 and a.is_current = 1)"
          , "(select count(*) from builds as a where a.finished = 1 and me.project = a.project and me.name = a.jobset and build_status = 0 and a.is_current = 1)"
          , "(select count(*) from builds as a where me.project = a.project and me.name = a.jobset and a.is_current = 1)"
          ]
        , "+as" => ["nrscheduled", "nrfailed", "nr_succeeded", "nrtotal"]
        });
}


sub jobsetOverview {
    my ($c, $project) = @_;
    my $jobsets = $project->jobsets->search(isProjectOwner($c, $project) ? {} : { hidden => 0 });
    return jobsetOverview_($c, $jobsets);
}


# Return the path of the build log of the given derivation, or undef
# if the log is gone.
sub getDrvLogPath {
    my ($drvPath) = @_;
    my $base = basename $drvPath;
    my $bucketed = substr($base, 0, 2) . "/" . substr($base, 2);
    my $fn = ($ENV{NIX_LOG_DIR} || "/nix/var/log/nix") . "/drvs/";
    my $fn2 = Hydra::Model::DB::getHydraPath . "/build-logs/";
    for ($fn2 . $bucketed, $fn2 . $bucketed . ".bz2", $fn . $bucketed . ".bz2", $fn . $bucketed, $fn . $base . ".bz2", $fn . $base) {
        return $_ if -f $_;
    }
    return undef;
}


# Find the log of the derivation denoted by $drvPath.  It it doesn't
# exist, try other derivations that produced its outputs (@outPaths).
sub findLog {
    my ($c, $drvPath, @outPaths) = @_;

    if (defined $drvPath) {
        my $logPath = getDrvLogPath($drvPath);
        return $logPath if defined $logPath;
    }

    return undef if scalar @outPaths == 0;

    my @steps = $c->model('DB::BuildSteps')->search(
        { path => { -in => [@outPaths] } },
        { select => ["drv_path"]
        , distinct => 1
        , join => "build_step_outputs"
        });

    foreach my $step (@steps) {
        next unless defined $step->drv_path;
        my $logPath = getDrvLogPath($step->drv_path);
        return $logPath if defined $logPath;
    }

    return undef;
}


sub logContents {
    my ($logPath, $tail) = @_;
    my $cmd;
    if ($logPath =~ /.bz2$/) {
        $cmd = "bzip2 -d < $logPath";
        $cmd = $cmd . " | tail -n $tail" if defined $tail;
    }
    else {
        $cmd = defined $tail ? "tail -$tail $logPath" : "cat $logPath";
    }
    return decode("utf-8", `$cmd`);
}


sub removeAsciiEscapes {
    my ($logtext) = @_;
    $logtext =~ s/\e\[[0-9]*[A-Za-z]//g;
    return $logtext;
}


sub getMainOutput {
    my ($build) = @_;
    return
        $build->build_outputs->find({name => "out"}) //
        $build->build_outputs->find({}, {limit => 1, order_by => ["name"]});
}


sub getEvalInputs {
    my ($c, $eval) = @_;
    my @inputs = $eval->jobset_eval_inputs->search(
        { -or => [ -and => [ uri => { '!=' => undef }, revision => { '!=' => undef }], dependency => { '!=' => undef }], alt_nr => 0 },
        { order_by => "name" });
}


sub getEvalInfo {
    my ($cache, $eval) = @_;
    my $res = $cache->{$eval->id}; return $res if defined $res;

    # Get stats for this eval.
    my $nrScheduled;
    my $nrSucceeded = $eval->nr_succeeded;
    if (defined $nrSucceeded) {
        $nrScheduled = 0;
    } else {
        $nrScheduled = $eval->builds->search({finished => 0})->count;
        $nrSucceeded = $eval->builds->search({finished => 1, build_status => 0})->count;
        if ($nrScheduled == 0) {
            $eval->update({nr_succeeded => $nrSucceeded});
        }
    }

    # Get the inputs.
    my @inputsList = $eval->jobset_eval_inputs->search(
        { -or => [ -and => [ uri => { '!=' => undef }, revision => { '!=' => undef }], dependency => { '!=' => undef }], alt_nr => 0 },
        { order_by => "name" });
    my $inputs;
    $inputs->{$_->name} = $_ foreach @inputsList;

    return $cache->{$eval->id} =
        { nrScheduled => $nrScheduled
        , nrSucceeded => $nrSucceeded
        , inputs => $inputs
        };
}


sub getEvals {
    my ($self, $c, $evals, $offset, $rows) = @_;

    my @evals = $evals->search(
        { has_new_builds => 1 },
        { order_by => "id DESC", rows => $rows, offset => $offset });

    my @res = ();
    my $cache = {};

    foreach my $curEval (@evals) {

        my ($prevEval) = $c->model('DB::JobsetEvals')->search(
            { project => $curEval->get_column('project'), jobset => $curEval->get_column('jobset')
            , has_new_builds => 1, id => { '<', $curEval->id } },
            { order_by => "id DESC", rows => 1 });

        my $curInfo = getEvalInfo($cache, $curEval);
        my $prevInfo = getEvalInfo($cache, $prevEval) if defined $prevEval;

        # Compute what inputs changed between each eval.
        my @changedInputs;
        foreach my $input (sort { $a->name cmp $b->name } values(%{$curInfo->{inputs}})) {
            my $p = $prevInfo->{inputs}->{$input->name};
            push @changedInputs, $input if
                !defined $p
                || ($input->revision || "") ne ($p->revision || "")
                || $input->type ne $p->type
                || ($input->uri || "") ne ($p->uri || "")
                || ($input->get_column('dependency') || "") ne ($p->get_column('dependency') || "");
        }

        push @res,
            { eval => $curEval
            , nrScheduled => $curInfo->{nrScheduled}
            , nrSucceeded => $curInfo->{nrSucceeded}
            , nrFailed => $curEval->nr_builds - $curInfo->{nrSucceeded} - $curInfo->{nrScheduled}
            , diff => defined $prevEval ? $curInfo->{nrSucceeded} - $prevInfo->{nrSucceeded} : 0
            , changedInputs => [ @changedInputs ]
            };
    }

    return [@res];
}


sub getMachines {
    my %machines = ();

    my @machinesFiles = split /:/, ($ENV{"NIX_REMOTE_SYSTEMS"} || "/etc/nix/machines");

    for my $machinesFile (@machinesFiles) {
        next unless -e $machinesFile;
        open CONF, "<$machinesFile" or die;
        while (<CONF>) {
            chomp;
            s/\#.*$//g;
            next if /^\s*$/;
            my @tokens = split /\s/, $_;
            my @supportedFeatures = split(/,/, $tokens[5] || "");
            my @mandatoryFeatures = split(/,/, $tokens[6] || "");
            $machines{$tokens[0]} =
                { systemTypes => [ split(/,/, $tokens[1]) ]
                , sshKeys => $tokens[2]
                , maxJobs => int($tokens[3])
                , speedFactor => 1.0 * (defined $tokens[4] ? int($tokens[4]) : 1)
                , supportedFeatures => [ @supportedFeatures, @mandatoryFeatures ]
                , mandatoryFeatures => [ @mandatoryFeatures ]
                };
        }
        close CONF;
    }

    return \%machines;
}


# Check whether ‘$path’ is inside ‘$prefix’.  In particular, it checks
# that resolving symlink components of ‘$path’ never takes us outside
# of ‘$prefix’.  We use this to check that Nix build products don't
# refer to things outside of the Nix store (e.g. /etc/passwd) or to
# symlinks outside of the store that point into the store
# (e.g. /run/current-system).  Return undef or the resolved path.
sub pathIsInsidePrefix {
    my ($path, $prefix) = @_;
    my $n = 0;
    $path =~ s/\/+/\//g; # remove redundant slashes
    $path =~ s/\/*$//; # remove trailing slashes

    return undef unless $path eq $prefix || substr($path, 0, length($prefix) + 1) eq "$prefix/";

    my @cs = File::Spec->splitdir(substr($path, length($prefix) + 1));
    my $cur = $prefix;

    foreach my $c (@cs) {
        next if $c eq ".";

        # ‘..’ should not take us outside of the prefix.
        if ($c eq "..") {
            return if length($cur) <= length($prefix);
            $cur =~ s/\/[^\/]*$// or die; # remove last component
            next;
        }

        my $new = "$cur/$c";
        if (-l $new) {
            my $link = readlink $new or return undef;
            $new = substr($link, 0, 1) eq "/" ? $link : "$cur/$link";
            $new = pathIsInsidePrefix($new, $prefix);
            return undef unless defined $new;
        }
        $cur = $new;
    }

    return $cur;
}


sub captureStdoutStderr {
    my ($timeout, @cmd) = @_;
    my $stdin = "";
    my $stdout;
    my $stderr;

    eval {
        local $SIG{ALRM} = sub { die "timeout\n" }; # NB: \n required
        alarm $timeout;
        IPC::Run::run(\@cmd, \$stdin, \$stdout, \$stderr);
        alarm 0;
    };

    if ($@) {
        die unless $@ eq "timeout\n"; # propagate unexpected errors
        return (-1, "", "timeout\n");
    } else {
        return ($?, $stdout, $stderr);
    }
}


sub run {
    my (%args) = @_;
    my $res = { stdout => "", stderr => "" };
    my $stdin = "";

    eval {
        local $SIG{ALRM} = sub { die "timeout\n" }; # NB: \n required
        alarm $args{timeout} if defined $args{timeout};
        my @x = ($args{cmd}, \$stdin, \$res->{stdout});
        push @x, \$res->{stderr} if $args{grabStderr} // 1;
        IPC::Run::run(@x,
            init => sub { chdir $args{dir} or die "changing to $args{dir}" if defined $args{dir}; });
        alarm 0;
    };

    if ($@) {
        die unless $@ eq "timeout\n"; # propagate unexpected errors
        $res->{status} = -1;
        $res->{stderr} = "timeout\n";
    } else {
        $res->{status} = $?;
        chomp $res->{stdout} if $args{chomp} // 0;
    }

    return $res;
}


sub grab {
    my (%args) = @_;
    my $res = run(%args, grabStderr => 0);
    die "command `@{$args{cmd}}' failed with exit status $res->{status}" if $res->{status};
    return $res->{stdout};
}


sub getTotalShares {
    my ($db) = @_;
    return $db->resultset('Jobsets')->search(
        { 'project.enabled' => 1, 'me.enabled' => { '!=' => 0 } },
        { join => 'project', select => { sum => 'scheduling_shares' }, as => 'sum' })->single->get_column('sum');
}


sub cancelBuilds($$) {
    my ($db, $builds) = @_;
    return txn_do($db, sub {
        $builds = $builds->search({ finished => 0 });
        my $n = $builds->count;
        my $time = time();
        $builds->update(
            { finished => 1,
            , is_cached_build => 0, build_status => 4 # = cancelled
            , start_time => $time
            , stop_time => $time
            });
        return $n;
    });
}


sub restartBuilds($$) {
    my ($db, $builds) = @_;

    $builds = $builds->search({ finished => 1 });

    foreach my $build ($builds->search({}, { columns => ["drv_path"] })) {
        next if !isValidPath($build->drv_path);
        registerRoot $build->drv_path;
    }

    my $nrRestarted = 0;

    txn_do($db, sub {
        # Reset the stats for the evals to which the builds belongs.
        # !!! Should do this in a trigger.
        $db->resultset('JobsetEvals')->search(
            { id => { -in => $builds->search({}, { join => { 'jobset_eval_members' => 'eval' }, select => "jobset_eval_members.eval", as => "eval", distinct => 1 })->as_query }
            })->update({ nr_succeeded => undef });

        # Clear the failed paths cache.
        # FIXME: Add this to the API.
        my $cleared = $db->resultset('FailedPaths')->search(
            { path => { -in => $builds->search({}, { join => "build_outputs", select => "build_outputs.path", as => "path", distinct => 1 })->as_query }
            })->delete;
        $cleared += $db->resultset('FailedPaths')->search(
            { path => { -in => $builds->search({}, { join => "build_step_outputs", select => "build_step_outputs.path", as => "path", distinct => 1 })->as_query }
            })->delete;
        print STDERR "cleared $cleared failed paths\n";

        $nrRestarted = $builds->update(
            { finished => 0
            , is_cached_build => 0
            });
    });

    return $nrRestarted;
}


1;
