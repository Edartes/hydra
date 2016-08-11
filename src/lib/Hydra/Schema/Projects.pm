use utf8;
package Hydra::Schema::Projects;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::Projects

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 COMPONENTS LOADED

=over 4

=item * L<Hydra::Component::ToJSON>

=back

=cut

__PACKAGE__->load_components("+Hydra::Component::ToJSON");

=head1 TABLE: C<projects>

=cut

__PACKAGE__->table("projects");

=head1 ACCESSORS

=head2 name

  data_type: 'text'
  is_nullable: 0

=head2 display_name

  data_type: 'text'
  is_nullable: 0

=head2 description

  data_type: 'text'
  is_nullable: 1

=head2 enabled

  data_type: 'integer'
  default_value: 1
  is_nullable: 0

=head2 hidden

  data_type: 'integer'
  default_value: 0
  is_nullable: 0

=head2 owner

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=head2 homepage

  data_type: 'text'
  is_nullable: 1

=head2 declfile

  data_type: 'text'
  is_nullable: 1

=head2 decltype

  data_type: 'text'
  is_nullable: 1

=head2 declprops

  data_type: 'jsonb'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "name",
  { data_type => "text", is_nullable => 0 },
  "display_name",
  { data_type => "text", is_nullable => 0 },
  "description",
  { data_type => "text", is_nullable => 1 },
  "enabled",
  { data_type => "integer", default_value => 1, is_nullable => 0 },
  "hidden",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
  "owner",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
  "homepage",
  { data_type => "text", is_nullable => 1 },
  "declfile",
  { data_type => "text", is_nullable => 1 },
  "decltype",
  { data_type => "text", is_nullable => 1 },
  "declprops",
  { data_type => "jsonb", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</name>

=back

=cut

__PACKAGE__->set_primary_key("name");

=head1 RELATIONS

=head2 build_metrics

Type: has_many

Related object: L<Hydra::Schema::BuildMetrics>

=cut

__PACKAGE__->has_many(
  "build_metrics",
  "Hydra::Schema::BuildMetrics",
  { "foreign.project" => "self.name" },
  undef,
);

=head2 builds

Type: has_many

Related object: L<Hydra::Schema::Builds>

=cut

__PACKAGE__->has_many(
  "builds",
  "Hydra::Schema::Builds",
  { "foreign.project" => "self.name" },
  undef,
);

=head2 jobs

Type: has_many

Related object: L<Hydra::Schema::Jobs>

=cut

__PACKAGE__->has_many(
  "jobs",
  "Hydra::Schema::Jobs",
  { "foreign.project" => "self.name" },
  undef,
);

=head2 jobset_evals

Type: has_many

Related object: L<Hydra::Schema::JobsetEvals>

=cut

__PACKAGE__->has_many(
  "jobset_evals",
  "Hydra::Schema::JobsetEvals",
  { "foreign.project" => "self.name" },
  undef,
);

=head2 jobset_renames

Type: has_many

Related object: L<Hydra::Schema::JobsetRenames>

=cut

__PACKAGE__->has_many(
  "jobset_renames",
  "Hydra::Schema::JobsetRenames",
  { "foreign.project" => "self.name" },
  undef,
);

=head2 jobsets

Type: has_many

Related object: L<Hydra::Schema::Jobsets>

=cut

__PACKAGE__->has_many(
  "jobsets",
  "Hydra::Schema::Jobsets",
  { "foreign.project" => "self.name" },
  undef,
);

=head2 owner

Type: belongs_to

Related object: L<Hydra::Schema::Users>

=cut

__PACKAGE__->belongs_to(
  "owner",
  "Hydra::Schema::Users",
  { username => "owner" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "CASCADE" },
);

=head2 project_members

Type: has_many

Related object: L<Hydra::Schema::ProjectMembers>

=cut

__PACKAGE__->has_many(
  "project_members",
  "Hydra::Schema::ProjectMembers",
  { "foreign.project" => "self.name" },
  undef,
);

=head2 release_members

Type: has_many

Related object: L<Hydra::Schema::ReleaseMembers>

=cut

__PACKAGE__->has_many(
  "release_members",
  "Hydra::Schema::ReleaseMembers",
  { "foreign.project" => "self.name" },
  undef,
);

=head2 releases

Type: has_many

Related object: L<Hydra::Schema::Releases>

=cut

__PACKAGE__->has_many(
  "releases",
  "Hydra::Schema::Releases",
  { "foreign.project" => "self.name" },
  undef,
);

=head2 starred_jobs

Type: has_many

Related object: L<Hydra::Schema::StarredJobs>

=cut

__PACKAGE__->has_many(
  "starred_jobs",
  "Hydra::Schema::StarredJobs",
  { "foreign.project" => "self.name" },
  undef,
);

=head2 usernames

Type: many_to_many

Composing rels: L</project_members> -> username

=cut

__PACKAGE__->many_to_many("usernames", "project_members", "username");


# Created by DBIx::Class::Schema::Loader v0.07045 @ 2016-08-11 10:41:51
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:P4vuUa5AygQNEAYXe8neIA

my %hint = (
    columns => [
        "name",
        "display_name",
        "description",
        "enabled",
        "hidden",
        "owner"
    ],
    relations => {
        releases => "name",
        jobsets => "name"
    }
);

sub json_hint {
    return \%hint;
}

1;
