use utf8;
package Hydra::Schema::ReleaseMembers;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::ReleaseMembers

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 TABLE: C<ReleaseMembers>

=cut

__PACKAGE__->table("ReleaseMembers");

=head1 ACCESSORS

=head2 project

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=head2 release_

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=head2 build

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=head2 description

  data_type: 'text'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "project",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
  "release_",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
  "build",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "description",
  { data_type => "text", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</project>

=item * L</release_>

=item * L</build>

=back

=cut

__PACKAGE__->set_primary_key("project", "release_", "build");

=head1 RELATIONS

=head2 build

Type: belongs_to

Related object: L<Hydra::Schema::Builds>

=cut

__PACKAGE__->belongs_to("build", "Hydra::Schema::Builds", { id => "build" }, {});

=head2 project

Type: belongs_to

Related object: L<Hydra::Schema::Projects>

=cut

__PACKAGE__->belongs_to("project", "Hydra::Schema::Projects", { name => "project" }, {});

=head2 release

Type: belongs_to

Related object: L<Hydra::Schema::Releases>

=cut

__PACKAGE__->belongs_to(
  "release",
  "Hydra::Schema::Releases",
  { name => "release_", project => "project" },
  {},
);


# Created by DBIx::Class::Schema::Loader v0.07014 @ 2011-12-05 14:15:43
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:SBMfzENPE0BjEwc2HAK7IA

1;
