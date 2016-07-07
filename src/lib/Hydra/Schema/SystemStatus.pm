use utf8;
package Hydra::Schema::SystemStatus;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::SystemStatus

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

=head1 TABLE: C<system_status>

=cut

__PACKAGE__->table("system_status");

=head1 ACCESSORS

=head2 what

  data_type: 'text'
  is_nullable: 0

=head2 status

  data_type: 'json'
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "what",
  { data_type => "text", is_nullable => 0 },
  "status",
  { data_type => "json", is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</what>

=back

=cut

__PACKAGE__->set_primary_key("what");


# Created by DBIx::Class::Schema::Loader v0.07045 @ 2016-07-07 08:50:21
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:4q/nI7C/vlApwwSLnAowfw


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
