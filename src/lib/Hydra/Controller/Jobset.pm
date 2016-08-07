package Hydra::Controller::Jobset;

use utf8;
use strict;
use warnings;
use base 'Hydra::Base::Controller::ListBuilds';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;

use JSON qw(encode_json);

sub jobsetChain :Chained('/') :PathPart('jobset') :CaptureArgs(2) {
    my ($self, $c, $projectName, $jobsetName) = @_;

    my $project = $c->model('DB::Projects')->find($projectName);

    notFound($c, "Project ‘$projectName’ doesn't exist.") if !$project;

    $c->stash->{project} = $project;

    %{$c->stash->{inputTypeNames}} = map {
        $_ => $c->stash->{inputTypes}->{$_}->{name}
    } keys $c->stash->{inputTypes};

    $c->stash->{jobset} = $project->jobsets->find({ name => $jobsetName });

    if (!$c->stash->{jobset} && !($c->action->name eq "jobset" and $c->request->method eq "PUT")) {
        my $rename = $project->jobset_renames->find({ from_ => $jobsetName });
        notFound($c, "Jobset ‘$jobsetName’ doesn't exist.") unless defined $rename;

        # Return a permanent redirect to the new jobset name.
        my @captures = @{$c->req->captures};
        $captures[1] = $rename->to_;
        $c->res->redirect($c->uri_for($c->action, \@captures, $c->req->params), 301);
        $c->detach;
    }

    $c->stash->{params}->{name} //= $jobsetName;
}


sub jobset :Chained('jobsetChain') :PathPart('') :Args(0) :ActionClass('REST::ForBrowsers') { }

sub jobset_GET {
    my ($self, $c) = @_;

    $c->stash->{template} = 'jobset.tt';

    $c->stash->{evals} = getEvals($self, $c, scalar $c->stash->{jobset}->jobset_evals, 0, 10);

    $c->stash->{latestEval} = $c->stash->{jobset}->jobset_evals->search({}, { rows => 1, order_by => ["id desc"] })->single;

    $c->stash->{totalShares} = getTotalShares($c->model('DB')->schema);

    my $result = $c->stash->{jobset}->TO_JSON;

    foreach my $key (keys %{$result->{jobset_inputs}}) {
        my $input = $result->{jobset_inputs}->{$key}->TO_JSON;
        $input->{properties} = cleanProperties(
            $c, $input->{properties}, $input->{type}
        );
        $result->{jobset_inputs}->{$key} = $input;
    }

    $self->status_ok($c, entity => $result);
}

sub jobset_PUT {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{project});

    if (length($c->stash->{project}->declfile)) {
        error($c, "can't modify jobset of declarative project", 403);
    }

    if (defined $c->stash->{jobset}) {
        txn_do($c->model('DB')->schema, sub {
            updateJobset($c, $c->stash->{jobset});
        });

        my $uri = $c->uri_for($self->action_for("jobset"), [$c->stash->{project}->name, $c->stash->{jobset}->name]) . "#tabs-configuration";
        $self->status_ok($c, entity => { redirect => "$uri" });

        $c->flash->{successMsg} = "The jobset configuration has been updated.";
    }

    else {
        my $jobset;
        txn_do($c->model('DB')->schema, sub {
            # Note: $jobsetName is validated in updateProject, which will
            # abort the transaction if the name isn't valid.
            $jobset = $c->stash->{project}->jobsets->create(
                {name => ".tmp", nix_expr_input => "", nix_expr_path => "", email_override => ""});
            updateJobset($c, $jobset);
        });

        my $uri = $c->uri_for($self->action_for("jobset"), [$c->stash->{project}->name, $jobset->name]);
        $self->status_created($c,
            location => "$uri",
            entity => { name => $jobset->name, uri => "$uri", redirect => "$uri", type => "jobset" });
    }
}

sub jobset_DELETE {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{project});

    if (length($c->stash->{project}->declfile)) {
        error($c, "can't modify jobset of declarative project", 403);
    }

    txn_do($c->model('DB')->schema, sub {
        $c->stash->{jobset}->jobset_evals->delete;
        $c->stash->{jobset}->builds->delete;
        $c->stash->{jobset}->delete;
    });

    my $uri = $c->uri_for($c->controller('Project')->action_for("project"), [$c->stash->{project}->name]);
    $self->status_ok($c, entity => { redirect => "$uri" });

    $c->flash->{successMsg} = "The jobset has been deleted.";
}

sub jobset_OPTIONS {
    my ($self, $c) = @_;

    my $spec = $c->stash->{inputTypes};

    # Remove all validate attributes, because they're solely meant for the
    # backend side and also cannot be serialized into JSON. This is done
    # destructively on $c->stash->${inputTypes} because we won't re-use it
    # within the OPTIONS request at some later point.
    foreach my $type (keys %$spec) {
        if (exists $spec->{$type}->{singleton}) {
            delete $spec->{$type}->{singleton}->{validate};
        } else {
            foreach my $key (keys %{$spec->{$type}->{properties}}) {
                delete $spec->{$type}->{properties}->{$key}->{validate};
            }
        }
    }

    $self->status_ok($c, entity => $spec);
}


sub jobs_tab : Chained('jobsetChain') PathPart('jobs-tab') Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'jobset-jobs-tab.tt';

    $c->stash->{filter} = $c->request->params->{filter} // "";
    my $filter = "%" . $c->stash->{filter} . "%";

    my ($evals, $builds) = searchBuildsAndEvalsForJobset(
        $c->stash->{jobset},
        { job => { ilike => $filter }, is_channel => 0 },
        10000
    );

    if ($c->request->params->{showInactive}) {
        $c->stash->{showInactive} = 1;
        foreach my $job ($c->stash->{jobset}->jobs->search({ name => { ilike => $filter } })) {
            next if defined $builds->{$job->name};
            $c->stash->{inactiveJobs}->{$job->name} = $builds->{$job->name} = 1;
        }
    }

    $c->stash->{evals} = $evals;
    my @jobs = sort (keys %$builds);
    $c->stash->{nrJobs} = scalar @jobs;
    splice @jobs, 250 if $c->stash->{filter} eq "";
    $c->stash->{jobs} = [@jobs];
}


sub channels_tab : Chained('jobsetChain') PathPart('channels-tab') Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'jobset-channels-tab.tt';

    my ($evals, $builds) = searchBuildsAndEvalsForJobset(
        $c->stash->{jobset},
        { is_channel => 1 }
    );

    $c->stash->{evals} = $evals;
    my @channels = sort (keys %$builds);
    $c->stash->{channels} = [@channels];
}


# Hydra::Base::Controller::ListBuilds needs this.
sub get_builds : Chained('jobsetChain') PathPart('') CaptureArgs(0) {
    my ($self, $c) = @_;
    $c->stash->{allBuilds} = $c->stash->{jobset}->builds;
    $c->stash->{latestSucceeded} = $c->model('DB')->resultset('LatestSucceededForJobset')
        ->search({}, {bind => [$c->stash->{project}->name, $c->stash->{jobset}->name]});
    $c->stash->{channelBaseName} =
        $c->stash->{project}->name . "-" . $c->stash->{jobset}->name;
}


sub edit : Chained('jobsetChain') PathPart Args(0) {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{project});

    $c->stash->{template} = 'edit-jobset.tt';
    $c->stash->{encode_json} = \&encode_json;
    $c->stash->{edit} = !defined $c->stash->{params}->{cloneJobset};
    $c->stash->{cloneJobset} = defined $c->stash->{params}->{cloneJobset};
    $c->stash->{totalShares} = getTotalShares($c->model('DB')->schema);
}


sub nixExprPathFromParams {
    my ($c) = @_;

    # The Nix expression path must be relative and can't contain ".." elements.
    my $nixExprPath = trim $c->stash->{params}->{"nixexprpath"};
    error($c, "Invalid Nix expression path ‘$nixExprPath’.") if $nixExprPath !~ /^$relPathRE$/;

    my $nixExprInput = trim $c->stash->{params}->{"nixexprinput"};
    error($c, "Invalid Nix expression input name ‘$nixExprInput’.") unless $nixExprInput =~ /^[[:alpha:]][\w-]*$/;

    return ($nixExprPath, $nixExprInput);
}


sub cleanProperty {
    my ($c, $spec, $value) = @_;

    return "**********" if exists $spec->{type} and $spec->{type} eq "secret";

    if ($spec->{properties}) {
        $value->{children} = cleanProperties(
            $c, $value->{children}, undef, $spec
        );
    }
    return $value;
}


sub cleanProperties {
    my ($c, $props, $type, $spec) = @_;

    $spec ||= $c->stash->{inputTypes}->{$type};

    if ($spec->{singleton}) {
        $props->{value} = cleanProperty(
            $c, $spec->{singleton}, $props->{value}
        );
    } else {
        foreach my $prop (keys %$props) {
            unless ($spec->{properties}->{$prop}) {
                delete $props->{$prop};
                next;
            }
            $props->{$prop} = cleanProperty(
                $c, $spec->{properties}->{$prop}, $props->{$prop}
            );
        }
    }
    return $props;
}


sub validateProperty {
    my ($c, $name, $typeDesc, $spec, $value) = @_;

    my $type = exists $spec->{type} ? $spec->{type} : "string";

    if (exists $spec->{properties}) {
        validateProperties($c, $name, $typeDesc, $value->{children}, $spec);
        $value = $value->{value};
    }

    if ($type eq "bool") {
        error($c, "The value ‘$value’ of input ‘$name’ is not a Boolean "
                . "(‘true’ or ‘false’).")
            unless $value eq "1" || $value eq "0";
    } elsif ($type eq "int") {
        error($c, "The value ‘$value’ of input ‘$name’ is not an Integer.")
            unless $value =~ /^\d+$/;
    } elsif ($type eq "attrset") {
        error($c, "The value ‘$value’ of input ‘$name’ is not an Attribute "
                . "Set. (‘{key1: \"value1\", key2: \"value2\"}’)")
            if grep { ref($value->{$_}) eq "" } keys %$value;
    } else {
        error($c, "The value ‘$value’ of input ‘$name’ is not a String.")
            unless ref($value) eq "";
    }

    if (exists $spec->{validate}) {
        $spec->{validate}->($c, $name, $value);
    }
}


sub validateProperties {
    my ($c, $name, $type, $properties, $spec) = @_;

    error($c, "Invalid input type ‘$type’ for input ‘$name’.")
        unless exists $c->stash->{inputTypes}->{$type};

    $spec ||= $c->stash->{inputTypes}->{$type};
    my $typeDesc = $spec->{name} // $type;

    if ($spec->{singleton}) {
        validateProperty($c, $name, $typeDesc, $spec->{singleton},
                         $properties->{value});
    } else {
        my $definedKeys = { %$properties };
        foreach my $key (keys %{$spec->{properties}}) {
            if (exists $properties->{$key}) {
                delete $definedKeys->{$key};
            } else {
                error($c, "Property ‘$key’ is mandatory for input ‘$name’"
                        . " and type ‘$typeDesc’.")
                    if $spec->{properties}->{$key}->{required};
                next;
            }

            validateProperty($c, $name, $type, $spec->{properties}->{$key},
                             $properties->{$key});
        }

        foreach my $key (keys %$definedKeys) {
            error($c, "Property ‘$key’ doesn't exist for input ‘$name’"
                    . " and type ‘$typeDesc’.");
        }
    }
}


sub updateJobset {
    my ($c, $jobset) = @_;

    my $oldName = $jobset->name;
    my $jobsetName = $c->stash->{params}->{name};
    error($c, "Invalid jobset identifier ‘$jobsetName’.") if $jobsetName !~ /^$jobsetNameRE$/;

    error($c, "Cannot rename jobset to ‘$jobsetName’ since that identifier is already taken.")
        if $jobsetName ne $oldName && defined $c->stash->{project}->jobsets->find({ name => $jobsetName });

    # When the expression is in a .scm file, assume it's a Guile + Guix
    # build expression.
    my $exprType =
        $c->stash->{params}->{"nixexprpath"} =~ /.scm$/ ? "guile" : "nix";

    my ($nixExprPath, $nixExprInput) = nixExprPathFromParams $c;

    my $enabled = int($c->stash->{params}->{enabled});
    die if $enabled < 0 || $enabled > 2;

    my $shares = int($c->stash->{params}->{schedulingshares} // 1);
    error($c, "The number of scheduling shares must be positive.") if $shares <= 0;

    $jobset->update(
        { name => $jobsetName
        , description => trim($c->stash->{params}->{"description"})
        , nix_expr_path => $nixExprPath
        , nix_expr_input => $nixExprInput
        , enabled => $enabled
        , enable_email => defined $c->stash->{params}->{enableemail} ? 1 : 0
        , email_override => trim($c->stash->{params}->{emailoverride}) || ""
        , hidden => defined $c->stash->{params}->{visible} ? 0 : 1
        , keepnr => int(trim($c->stash->{params}->{keepnr}))
        , check_interval => int(trim($c->stash->{params}->{checkinterval}))
        , trigger_time => $enabled ? $jobset->trigger_time // time() : undef
        , scheduling_shares => $shares
        });

    $jobset->project->jobset_renames->search({ from_ => $jobsetName })->delete;
    $jobset->project->jobset_renames->create({ from_ => $oldName, to_ => $jobsetName })
        if $oldName ne ".tmp" && $jobsetName ne $oldName;

    # Set the inputs of this jobset.
    $jobset->jobset_inputs->delete;

    foreach my $name (keys %{$c->stash->{params}->{inputs}}) {
        my $inputData = $c->stash->{params}->{inputs}->{$name};
        my $type = $inputData->{type};
        my $properties = $inputData->{properties};
        my $emailresponsible = defined $inputData->{emailresponsible} ? 1 : 0;

        error($c, "Invalid input name ‘$name’.") unless $name =~ /^[[:alpha:]][\w-]*$/;
        error($c, "Invalid input type ‘$type’.") unless defined $c->stash->{inputTypes}->{$type};

        validateProperties($c, $name, $type, $properties);

        my $input = $jobset->jobset_inputs->create(
            { name => $name,
              type => $type,
              email_responsible => $emailresponsible,
              properties => $properties
            });
    }
}


sub clone : Chained('jobsetChain') PathPart('clone') Args(0) {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{project});

    $c->stash->{template} = 'edit-jobset.tt';
    $c->stash->{cloneJobset} = 1;
    $c->stash->{totalShares} = getTotalShares($c->model('DB')->schema);
}


sub evals :Chained('jobsetChain') :PathPart('evals') :Args(0) :ActionClass('REST') { }

sub evals_GET {
    my ($self, $c) = @_;

    $c->stash->{template} = 'evals.tt';

    my $page = int($c->req->param('page') || "1") || 1;

    my $resultsPerPage = 20;

    my $evals = $c->stash->{jobset}->jobset_evals;

    $c->stash->{page} = $page;
    $c->stash->{resultsPerPage} = $resultsPerPage;
    $c->stash->{total} = $evals->search({has_new_builds => 1})->count;
    my $offset = ($page - 1) * $resultsPerPage;
    $c->stash->{evals} = getEvals($self, $c, $evals, $offset, $resultsPerPage);
    my %entity = (
        evals => [ map { $_->{eval} } @{$c->stash->{evals}} ],
        first => "?page=1",
        last => "?page=" . POSIX::ceil($c->stash->{total}/$resultsPerPage)
    );
    if ($page > 1) {
        $entity{previous} = "?page=" . ($page - 1);
    }
    if ($page < POSIX::ceil($c->stash->{total}/$resultsPerPage)) {
        $entity{next} = "?page=" . ($page + 1);
    }
    $self->status_ok(
        $c,
        entity => \%entity
    );
}


# Redirect to the latest finished evaluation of this jobset.
sub latest_eval : Chained('jobsetChain') PathPart('latest-eval') {
    my ($self, $c, @args) = @_;
    my $eval = getLatestFinishedEval($c->stash->{jobset})
        or notFound($c, "No evaluation found.");
    $c->res->redirect($c->uri_for($c->controller('JobsetEval')->action_for("view"), [$eval->id], @args, $c->req->params));
}


1;
