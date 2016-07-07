use utf8;
package Hydra::Schema::NewsItems;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::NewsItems

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

=head1 TABLE: C<news_items>

=cut

__PACKAGE__->table("news_items");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0
  sequence: 'news_items_id_seq'

=head2 contents

  data_type: 'text'
  is_nullable: 0

=head2 create_time

  data_type: 'integer'
  is_nullable: 0

=head2 author

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "id",
  {
    data_type         => "integer",
    is_auto_increment => 1,
    is_nullable       => 0,
    sequence          => "news_items_id_seq",
  },
  "contents",
  { data_type => "text", is_nullable => 0 },
  "create_time",
  { data_type => "integer", is_nullable => 0 },
  "author",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");

=head1 RELATIONS

=head2 author

Type: belongs_to

Related object: L<Hydra::Schema::Users>

=cut

__PACKAGE__->belongs_to(
  "author",
  "Hydra::Schema::Users",
  { username => "author" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "CASCADE" },
);


# Created by DBIx::Class::Schema::Loader v0.07045 @ 2016-07-07 08:50:21
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:6YQ/dGckaKyBrefbz8eDRw

1;
