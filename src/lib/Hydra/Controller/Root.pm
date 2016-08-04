package Hydra::Controller::Root;

use strict;
use warnings;
use base 'Hydra::Base::Controller::ListBuilds';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;
use Digest::SHA1 qw(sha1_hex);
use Nix::Store;
use Nix::Config;
use Encode;
use JSON;

# Put this controller at top-level.
__PACKAGE__->config->{namespace} = '';


sub noLoginNeeded {
  my ($c) = @_;

  return $c->request->path eq "persona-login" ||
         $c->request->path eq "google-login" ||
         $c->request->path eq "login" ||
         $c->request->path eq "logo" ||
         $c->request->path =~ /^static\//;
}


sub begin :Private {
    my ($self, $c, @args) = @_;

    $c->stash->{curUri} = $c->request->uri;
    $c->stash->{version} = $ENV{"HYDRA_RELEASE"} || "<devel>";
    $c->stash->{nixVersion} = $ENV{"NIX_RELEASE"} || "<devel>";
    $c->stash->{curTime} = time;
    $c->stash->{logo} = defined $c->config->{hydra_logo} ? "/logo" : "";
    $c->stash->{tracker} = $ENV{"HYDRA_TRACKER"};
    $c->stash->{flashMsg} = $c->flash->{flashMsg};
    $c->stash->{successMsg} = $c->flash->{successMsg};

    $c->stash->{isPrivateHydra} = $c->config->{private} // "0" ne "0";

    if ($c->stash->{isPrivateHydra} && ! noLoginNeeded($c)) {
        requireUser($c);
    }

    if (scalar(@args) == 0 || $args[0] ne "static") {
        $c->stash->{nrRunningbuilds} = dbh($c)->selectrow_array(
            "select count(distinct build) from build_steps where busy = 1");
        $c->stash->{nrQueuedBuilds} = $c->model('DB::Builds')->search({ finished => 0 })->count();
    }

    my $buildProperties = {
        job => {label => 'Job'},
        jobset => {label => 'Jobset', optional => 1},
        project => {label => 'Project', optional => 1},
        attrs => {
            label => "Attributes",
            type => "attrset",
            optional => 1,
        },
    };

    # Gather the supported input types.
    $c->stash->{inputTypes} = {
        'string' => {
            name => 'String value',
            singleton => {},
        },
        'boolean' => {
            name => 'Boolean',
            singleton => {type => "bool"},
        },
        'nix' => {
            name => 'Nix expression',
            singleton => {},
        },
        'build' => {
            name => 'Previous Hydra build',
            properties => $buildProperties,
        },
        'sysbuild' => {
            name => 'Previous Hydra build (same system)',
            properties => $buildProperties,
        },
        'eval' => {
            name => 'Previous Hydra evaluation',
            singleton => {type => "int"},
        },
    };

    $_->supportedInputTypes($c->stash->{inputTypes}) foreach @{$c->hydra_plugins};

    $c->forward('deserialize');

    $c->stash->{params} = $c->request->data or $c->request->params;
    unless (defined $c->stash->{params} and %{$c->stash->{params}}) {
        $c->stash->{params} = $c->request->params;
    }

    # Set the Vary header to "Accept" to ensure that browsers don't
    # mix up HTML and JSON responses.
    $c->response->headers->header('Vary', 'Accept');
}


sub deserialize :ActionClass('Deserialize') { }


sub index :Path :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'overview.tt';
    $c->stash->{projects} = [$c->model('DB::Projects')->search(isAdmin($c) ? {} : {hidden => 0}, {order_by => 'name'})];
    $c->stash->{newsItems} = [$c->model('DB::NewsItems')->search({}, { order_by => ['create_time DESC'], rows => 5 })];
    $self->status_ok($c,
        entity => $c->stash->{projects}
    );
}


sub queue :Local :Args(0) :ActionClass('REST') { }

sub queue_GET {
    my ($self, $c) = @_;
    $c->stash->{template} = 'queue.tt';
    $c->stash->{flashMsg} //= $c->flash->{buildMsg};
    $self->status_ok(
        $c,
        entity => [$c->model('DB::Builds')->search(
            { finished => 0 },
            { order_by => ["global_priority desc", "id"],
            , columns => [@buildListColumns]
            })]
    );
}


sub queue_summary :Local :Path('queue-summary') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'queue-summary.tt';

    $c->stash->{queued} = dbh($c)->selectall_arrayref(
        "select project, jobset, count(*) as queued, min(timestamp) as oldest, max(timestamp) as newest from builds " .
        "where finished = 0 group by project, jobset order by queued desc",
        { Slice => {} });

    $c->stash->{systems} = dbh($c)->selectall_arrayref(
        "select system, count(*) as c from builds where finished = 0 group by system order by c desc",
        { Slice => {} });
}


sub status :Local :Args(0) :ActionClass('REST') { }

sub status_GET {
    my ($self, $c) = @_;
    $self->status_ok(
        $c,
        entity => [$c->model('DB::Builds')->search(
            { "build_steps.busy" => 1 },
            { order_by => ["global_priority DESC", "id"],
              join => "build_steps",
              columns => [@buildListColumns]
            })]
    );
}


sub queue_runner_status :Local :Path('queue-runner-status') :Args(0) :ActionClass('REST') { }

sub queue_runner_status_GET {
    my ($self, $c) = @_;

    #my $status = from_json($c->model('DB::SystemStatus')->find('queue-runner')->status);
    my $status = from_json(`hydra-queue-runner --status`);
    if ($?) { $status->{status} = "unknown"; }
    my $json = JSON->new->pretty()->canonical();

    $c->stash->{template} = 'queue-runner-status.tt';
    $c->stash->{status} = $json->encode($status);
    $self->status_ok($c, entity => $status);
}


sub machines :Local Args(0) {
    my ($self, $c) = @_;
    my $machines = getMachines;

    # Add entry for localhost.
    $machines->{''} //= {};
    delete $machines->{'localhost'};

    my $status = $c->model('DB::SystemStatus')->find("queue-runner");
    if ($status) {
        my $ms = decode_json($status->status)->{"machines"};
        foreach my $name (keys %{$ms}) {
            $name = "" if $name eq "localhost";
            $machines->{$name} //= {disabled => 1};
            $machines->{$name}->{nrStepsDone} = $ms->{$name}->{nrStepsDone};
            $machines->{$name}->{avgStepBuildTime} = $ms->{$name}->{avgStepBuildTime} // 0;
        }
    }

    $c->stash->{machines} = $machines;
    $c->stash->{steps} = dbh($c)->selectall_arrayref(
        "select build, stepnr, s.system as system, s.drv_path as drv_path, machine, s.start_time as start_time, project, jobset, job " .
        "from build_steps s join builds b on s.build = b.id " .
        "where busy = 1 order by machine, stepnr",
        { Slice => {} });
    $c->stash->{template} = 'machine-status.tt';
}


# Hydra::Base::Controller::ListBuilds needs this.
sub get_builds : Chained('/') PathPart('') CaptureArgs(0) {
    my ($self, $c) = @_;
    $c->stash->{allBuilds} = $c->model('DB::Builds');
    $c->stash->{latestSucceeded} = $c->model('DB')->resultset('LatestSucceeded');
    $c->stash->{channelBaseName} = "everything";
    $c->stash->{total} = $c->model('DB::NrBuilds')->find('finished')->count;
}


sub robots_txt : Path('robots.txt') {
    my ($self, $c) = @_;

    sub uri_for {
        my ($c, $controller, $action, @args) = @_;
        return $c->uri_for($c->controller($controller)->action_for($action), @args)->path;
    }

    sub channelUris {
        my ($c, $controller, $bindings) = @_;
        return
            ( uri_for($c, $controller, 'closure', $bindings, "*")
            , uri_for($c, $controller, 'manifest', $bindings)
            , uri_for($c, $controller, 'pkg', $bindings, "*")
            , uri_for($c, $controller, 'nixexprs', $bindings)
            , uri_for($c, $controller, 'channel_contents', $bindings)
            );
    }

    # Put actions that are expensive or not useful for indexing in
    # robots.txt.  Note: wildcards are not universally supported in
    # robots.txt, but apparently Google supports them.
    my @rules =
        ( uri_for($c, 'Build', 'build', ["*"])
        , uri_for($c, 'Root', 'nar', [], "*")
        , uri_for($c, 'Root', 'status', [])
        , uri_for($c, 'Root', 'all', [])
        , uri_for($c, 'Root', 'queue', [])
        , uri_for($c, 'API', 'scmdiff', [])
        , uri_for($c, 'API', 'logdiff', [],"*", "*")
        , uri_for($c, 'Project', 'all', ["*"])
        , uri_for($c, 'Jobset', 'all', ["*", "*"])
        , uri_for($c, 'Job', 'all', ["*", "*", "*"])
        , channelUris($c, 'Root', ["*"])
        , channelUris($c, 'Project', ["*", "*"])
        , channelUris($c, 'Jobset', ["*", "*", "*"])
        , channelUris($c, 'Job', ["*", "*", "*", "*"])
        );

    $c->stash->{'plain'} = { data => "User-agent: *\n" . join('', map { "Disallow: $_\n" } @rules) };
    $c->forward('Hydra::View::Plain');
}


sub default :Path {
    my ($self, $c) = @_;
    notFound($c, "Page not found.");
}


sub end : ActionClass('RenderView') {
    my ($self, $c) = @_;

    if (defined $c->stash->{json}) {
        if (scalar @{$c->error}) {
            # FIXME: dunno why we need to do decode_utf8 here.
            $c->stash->{json}->{error} = join "\n", map { decode_utf8($_); } @{$c->error};
            $c->clear_errors;
        }
        $c->forward('View::JSON');
    }

    elsif (scalar @{$c->error}) {
        $c->stash->{resource} = { error => join "\n", @{$c->error} };
        $c->stash->{template} = 'error.tt';
        $c->stash->{errors} = $c->error;
        $c->response->status(500) if $c->response->status == 200;
        if ($c->response->status >= 300) {
            $c->stash->{httpStatus} =
                $c->response->status . " " . HTTP::Status::status_message($c->response->status);
        }
        $c->clear_errors;
    }

    $c->forward('serialize') if defined $c->stash->{resource};
}


sub serialize : ActionClass('Serialize') { }


sub nar :Local :Args(1) {
    my ($self, $c, $path) = @_;

    die if $path =~ /\//;

    my $storeMode = $c->config->{store_mode} // "direct";

    if ($storeMode eq "s3-binary-cache") {
        notFound($c, "There is no binary cache here.");
    }

    elsif ($storeMode eq "local-binary-cache") {
        my $dir = $c->config->{binary_cache_dir};
        $c->serve_static_file($dir . "/nar/" . $path);
    }

    else {
        $path = $Nix::Config::storeDir . "/$path";

        gone($c, "Path " . $path . " is no longer available.") unless isValidPath($path);

        $c->stash->{current_view} = 'NixNAR';
        $c->stash->{storePath} = $path;
    }
}


sub nix_cache_info :Path('nix-cache-info') :Args(0) {
    my ($self, $c) = @_;

    my $storeMode = $c->config->{store_mode} // "direct";

    if ($storeMode eq "s3-binary-cache") {
        notFound($c, "There is no binary cache here.");
    }

    elsif ($storeMode eq "local-binary-cache") {
        my $dir = $c->config->{binary_cache_dir};
        $c->serve_static_file($dir . "/nix-cache-info");
    }

    else {
        $c->response->content_type('text/plain');
        $c->stash->{plain}->{data} =
            "StoreDir: $Nix::Config::storeDir\n" .
            "WantMassQuery: 0\n" .
            # Give Hydra binary caches a very low priority (lower than the
            # static binary cache http://nixos.org/binary-cache).
            "Priority: 100\n";
        setCacheHeaders($c, 24 * 60 * 60);
        $c->forward('Hydra::View::Plain');
    }
}


sub narinfo :LocalRegex('^([a-z0-9]+).narinfo$') :Args(0) {
    my ($self, $c) = @_;

    my $storeMode = $c->config->{store_mode} // "direct";

    if ($storeMode eq "s3-binary-cache") {
        notFound($c, "There is no binary cache here.");
    }

    elsif ($storeMode eq "local-binary-cache") {
        my $dir = $c->config->{binary_cache_dir};
        $c->serve_static_file($dir . "/" . $c->req->captures->[0] . ".narinfo");
    }

    else {
        my $hash = $c->req->captures->[0];

        die if length($hash) != 32;
        my $path = queryPathFromHashPart($hash);

        if (!$path) {
            $c->response->status(404);
            $c->response->content_type('text/plain');
            $c->stash->{plain}->{data} = "does not exist\n";
            $c->forward('Hydra::View::Plain');
            setCacheHeaders($c, 60 * 60);
            return;
        }

        $c->stash->{storePath} = $path;
        $c->forward('Hydra::View::NARInfo');
    }
}


sub logo :Local {
    my ($self, $c) = @_;
    my $path = $c->config->{hydra_logo} // die("Logo not set!");
    $c->serve_static_file($path);
}


sub evals :Local Args(0) {
    my ($self, $c) = @_;

    $c->stash->{template} = 'evals.tt';

    my $page = int($c->req->param('page') || "1") || 1;

    my $resultsPerPage = 20;

    my $evals = $c->model('DB::JobsetEvals');

    $c->stash->{page} = $page;
    $c->stash->{resultsPerPage} = $resultsPerPage;
    $c->stash->{total} = $evals->search({has_new_builds => 1})->count;
    $c->stash->{evals} = getEvals($self, $c, $evals, ($page - 1) * $resultsPerPage, $resultsPerPage)
}


sub steps :Local Args(0) {
    my ($self, $c) = @_;

    $c->stash->{template} = 'steps.tt';

    my $page = int($c->req->param('page') || "1") || 1;

    my $resultsPerPage = 20;

    $c->stash->{page} = $page;
    $c->stash->{resultsPerPage} = $resultsPerPage;
    $c->stash->{steps} = [ $c->model('DB::BuildSteps')->search(
        { start_time => { '!=', undef },
          stop_time => { '!=', undef }
        },
        { order_by => [ "stop_time desc" ],
          rows => $resultsPerPage,
          offset => ($page - 1) * $resultsPerPage
        }) ];

    $c->stash->{total} = approxTableSize($c, "index_build_steps_on_stop_time");
}


sub search :Local Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'search.tt';

    my $query = trim $c->request->params->{"query"};

    error($c, "Query is empty.") if $query eq "";
    error($c, "Invalid character in query.")
        unless $query =~ /^[a-zA-Z0-9_\-\/.]+$/;

    $c->stash->{limit} = 500;

    $c->stash->{projects} = [ $c->model('DB::Projects')->search(
        { -and =>
            [ { -or => [ name => { ilike => "%$query%" }, display_name => { ilike => "%$query%" }, description => { ilike => "%$query%" } ] }
            , { hidden => 0 }
            ]
        },
        { order_by => ["name"] } ) ];

    $c->stash->{jobsets} = [ $c->model('DB::Jobsets')->search(
        { -and =>
            [ { -or => [ "me.name" => { ilike => "%$query%" }, "me.description" => { ilike => "%$query%" } ] }
            , { "project.hidden" => 0, "me.hidden" => 0 }
            ]
        },
        { order_by => ["project", "name"], join => ["project"] } ) ];

    $c->stash->{jobs} = [ $c->model('DB::Jobs')->search(
        { "me.name" => { ilike => "%$query%" }
        , "project.hidden" => 0
        , "jobset.hidden" => 0
        },
        { order_by => ["enabled_ desc", "project", "jobset", "name"], join => ["project", "jobset"]
        , "+select" => [\ "(project.enabled = 1 and jobset.enabled = 1 and exists (select 1 from builds where project = project.name and jobset = jobset.name and job = me.name and is_current = 1)) as enabled_"]
        , "+as" => ["enabled"]
        , rows => $c->stash->{limit} + 1
        } ) ];

    # Perform build search in separate queries to prevent seq scan on buildoutputs table.
    $c->stash->{builds} = [ $c->model('DB::Builds')->search(
        { "build_outputs.path" => trim($query) },
        { order_by => ["id desc"], join => ["build_outputs"] } ) ];

    $c->stash->{buildsdrv} = [ $c->model('DB::Builds')->search(
        { "drv_path" => trim($query) },
        { order_by => ["id desc"] } ) ];
}


sub log :Local :Args(1) {
    my ($self, $c, $path) = @_;

    $path = ($ENV{NIX_STORE_DIR} || "/nix/store")."/$path";

    my @outpaths = ($path);
    my $logPath = findLog($c, $path, @outpaths);
    notFound($c, "The build log of $path is not available.") unless defined $logPath;

    $c->stash->{logPath} = $logPath;
    $c->forward('Hydra::View::NixLog');
}


1;
