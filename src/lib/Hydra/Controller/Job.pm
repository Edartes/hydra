package Hydra::Controller::Job;

use strict;
use warnings;
use base 'Hydra::Base::Controller::ListBuilds';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


sub job : Chained('/') PathPart('job') CaptureArgs(3) {
    my ($self, $c, $projectName, $jobsetName, $jobName) = @_;

    $c->stash->{jobset} = $c->model('DB::Jobsets')->find({ project => $projectName, name => $jobsetName });

    if (!$c->stash->{jobset}) {
        my $rename = $c->model('DB::JobsetRenames')->find({ project => $projectName, from_ => $jobsetName });
        notFound($c, "Jobset ‘$jobsetName’ doesn't exist.") unless defined $rename;

        # Return a permanent redirect to the new jobset name.
        my @captures = @{$c->req->captures};
        $captures[1] = $rename->to_;
        $c->res->redirect($c->uri_for($c->action, \@captures, $c->req->params), 301);
        $c->detach;
    }

    $c->stash->{job} = $c->stash->{jobset}->jobs->find({ name => $jobName })
        or notFound($c, "Job $projectName:$jobsetName:$jobName doesn't exist.");
    $c->stash->{project} = $c->stash->{job}->project;
}


sub overview : Chained('job') PathPart('') Args(0) {
    my ($self, $c) = @_;
    my $job = $c->stash->{job};

    $c->stash->{template} = 'job.tt';

    $c->stash->{lastBuilds} =
        [ $job->builds->search({ finished => 1 },
            { order_by => 'id DESC', rows => 10, columns => [@buildListColumns] }) ];

    $c->stash->{queuedBuilds} = [
        $job->builds->search(
            { finished => 0 },
            { order_by => ["priority DESC", "id"] }
        ) ];

    # If this is an aggregate job, then get its constituents.
    my @constituents = $c->model('DB::Builds')->search(
        { aggregate => { -in => $job->builds->search({}, { columns => ["id"], order_by => "id desc", rows => 15 })->as_query } },
        { join => 'aggregate_constituents_constituents', 
          columns => ['id', 'job', 'finished', 'build_status'],
          +select => ['aggregate_constituents_constituents.aggregate'],
          +as => ['aggregate']
        });

    my $aggregates = {};
    my %constituentJobs;
    foreach my $b (@constituents) {
        my $jobName = $b->get_column('job');
        $aggregates->{$b->get_column('aggregate')}->{constituents}->{$jobName} =
            { id => $b->id, finished => $b->finished, build_status => $b->build_status };
        $constituentJobs{$jobName} = 1;
    }

    foreach my $agg (keys %$aggregates) {
        # FIXME: could be done in one query.
        $aggregates->{$agg}->{build} = 
            $c->model('DB::Builds')->find({id => $agg}, {columns => [@buildListColumns]}) or die;
    }

    $c->stash->{aggregates} = $aggregates;
    $c->stash->{constituentJobs} = [sort (keys %constituentJobs)];

    $c->stash->{starred} = $c->user->starred_jobs(
        { project => $c->stash->{project}->name
        , jobset => $c->stash->{jobset}->name
        , job => $c->stash->{job}->name
        })->count == 1 if $c->user_exists;
}


sub metrics_tab : Chained('job') PathPart('metrics-tab') Args(0) {
    my ($self, $c) = @_;
    my $job = $c->stash->{job};
    $c->stash->{template} = 'job-metrics-tab.tt';
    $c->stash->{metrics} = [ $job->build_metrics->search(
        { }, { select => ["name"], distinct => 1, order_by => "name",  }) ];
}


sub build_times : Chained('job') PathPart('build-times') Args(0) {
    my ($self, $c) = @_;
    my @res = $c->stash->{job}->builds->search(
        { finished => 1, build_status => 0, closure_size => { '!=', 0 } },
        { join => "actualBuildStep"
        , "+select" => ["actualBuildStep.stop_time - actualBuildStep.start_time"]
        , "+as" => ["actualBuildTime"],
        , order_by => "id" });
    $self->status_ok($c, entity => [ map { { id => $_->id, timestamp => $_ ->timestamp, value => $_->get_column('actualBuildTime') } } @res ]);
}


sub closure_sizes : Chained('job') PathPart('closure-sizes') Args(0) {
    my ($self, $c) = @_;
    my @res = $c->stash->{job}->builds->search(
        { finished => 1, build_status => 0, closure_size => { '!=', 0 } },
        { order_by => "id", columns => [ "id", "timestamp", "closure_size" ] });
    $self->status_ok($c, entity => [ map { { id => $_->id, timestamp => $_ ->timestamp, value => $_->closure_size } } @res ]);
}


sub output_sizes : Chained('job') PathPart('output-sizes') Args(0) {
    my ($self, $c) = @_;
    my @res = $c->stash->{job}->builds->search(
        { finished => 1, build_status => 0, size => { '!=', 0 } },
        { order_by => "id", columns => [ "id", "timestamp", "size" ] });
    $self->status_ok($c, entity => [ map { { id => $_->id, timestamp => $_ ->timestamp, value => $_->size } } @res ]);
}


sub metric : Chained('job') PathPart('metric') Args(1) {
    my ($self, $c, $metricName) = @_;

    $c->stash->{template} = 'metric.tt';
    $c->stash->{metricName} = $metricName;

    my @res = $c->stash->{job}->build_metrics->search(
        { name => $metricName },
        { order_by => "timestamp", columns => [ "build", "name", "timestamp", "value", "unit" ] });

    $self->status_ok($c, entity => [ map { { id => $_->get_column("build"), timestamp => $_ ->timestamp, value => $_->value, unit => $_->unit } } @res ]);
}


# Hydra::Base::Controller::ListBuilds needs this.
sub get_builds : Chained('job') PathPart('') CaptureArgs(0) {
    my ($self, $c) = @_;
    $c->stash->{allBuilds} = $c->stash->{job}->builds;
    $c->stash->{latestSucceeded} = $c->model('DB')->resultset('LatestSucceededForJob')
        ->search({}, {bind => [$c->stash->{project}->name, $c->stash->{jobset}->name, $c->stash->{job}->name]});
    $c->stash->{channelBaseName} =
        $c->stash->{project}->name . "-" . $c->stash->{jobset}->name . "-" . $c->stash->{job}->name;
}


sub star : Chained('job') PathPart('star') Args(0) {
    my ($self, $c) = @_;
    requirePost($c);
    requireUser($c);
    my $args =
        { project => $c->stash->{project}->name
        , jobset => $c->stash->{jobset}->name
        , job => $c->stash->{job}->name
        };
    if ($c->request->params->{star} eq "1") {
        $c->user->starred_jobs->update_or_create($args);
    } else {
        $c->user->starred_jobs->find($args)->delete;
    }
    $c->stash->{resource}->{success} = 1;
}


1;
