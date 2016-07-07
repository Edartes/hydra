use strict;
use File::Basename;
use Hydra::Model::DB;
use Hydra::Helper::Nix;
use Nix::Store;
use Cwd;

my $db = Hydra::Model::DB->new;

use Test::Simple tests => 6;

$db->resultset('Users')->create({ username => "root", email_address => 'root@invalid.org', password => '' });

$db->resultset('Projects')->create({name => "tests", display_name => "", owner => "root"});
my $project = $db->resultset('Projects')->update_or_create({name => "tests", display_name => "", owner => "root"});
my $jobset = $project->jobsets->create({name => "basic", nix_expr_input => "jobs", nix_expr_path => "default.nix", email_override => ""});

my $jobsetinput;

$jobsetinput = $jobset->jobset_inputs->create({name => "jobs", type => "path"});
$jobsetinput->jobset_input_alts->create({alt_nr => 0, value => getcwd . "/jobs"});
system("hydra-evaluator " . $jobset->project->name . " " . $jobset->name);

my $successful_hash;
foreach my $build ($jobset->builds->search({finished => 0})) {
    system("hydra-build " . $build->id);
    my @outputs = $build->build_outputs->all;
    my $hash = substr basename($outputs[0]->path), 0, 32;
    if ($build->job->name eq "job") {
        ok(-e "/tmp/s3/hydra/$hash.nar", "The nar of a successful matched build is uploaded");
        ok(-e "/tmp/s3/hydra/$hash.narinfo", "The narinfo of a successful matched build is uploaded");
        $successful_hash = $hash;
    }
}

system("hydra-s3-backup-collect-garbage");
ok(-e "/tmp/s3/hydra/$successful_hash.nar", "The nar of a build that's a root is not removed by gc");
ok(-e "/tmp/s3/hydra/$successful_hash.narinfo", "The narinfo of a build that's a root is not removed by gc");

my $gcRootsDir = getGCRootsDir;
opendir DIR, $gcRootsDir or die;
while(readdir DIR) {
    next if $_ eq "." or $_ eq "..";
    unlink "$gcRootsDir/$_";
}
closedir DIR;
system("hydra-s3-backup-collect-garbage");
ok(not -e "/tmp/s3/hydra/$successful_hash.nar", "The nar of a build that's not a root is removed by gc");
ok(not -e "/tmp/s3/hydra/$successful_hash.narinfo", "The narinfo of a build that's not a root is removed by gc");
