use utf8;
package Hydra::Schema::BuildProducts;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::BuildProducts

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

=head1 TABLE: C<build_products>

=cut

__PACKAGE__->table("build_products");

=head1 ACCESSORS

=head2 build

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=head2 productnr

  data_type: 'integer'
  is_nullable: 0

=head2 type

  data_type: 'text'
  is_nullable: 0

=head2 subtype

  data_type: 'text'
  is_nullable: 0

=head2 file_size

  data_type: 'bigint'
  is_nullable: 1

=head2 sha1hash

  data_type: 'text'
  is_nullable: 1

=head2 sha256hash

  data_type: 'text'
  is_nullable: 1

=head2 path

  data_type: 'text'
  is_nullable: 1

=head2 name

  data_type: 'text'
  is_nullable: 0

=head2 default_path

  data_type: 'text'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "build",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "productnr",
  { data_type => "integer", is_nullable => 0 },
  "type",
  { data_type => "text", is_nullable => 0 },
  "subtype",
  { data_type => "text", is_nullable => 0 },
  "file_size",
  { data_type => "bigint", is_nullable => 1 },
  "sha1hash",
  { data_type => "text", is_nullable => 1 },
  "sha256hash",
  { data_type => "text", is_nullable => 1 },
  "path",
  { data_type => "text", is_nullable => 1 },
  "name",
  { data_type => "text", is_nullable => 0 },
  "default_path",
  { data_type => "text", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</build>

=item * L</productnr>

=back

=cut

__PACKAGE__->set_primary_key("build", "productnr");

=head1 RELATIONS

=head2 build

Type: belongs_to

Related object: L<Hydra::Schema::Builds>

=cut

__PACKAGE__->belongs_to(
  "build",
  "Hydra::Schema::Builds",
  { id => "build" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07045 @ 2016-07-07 08:50:21
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:48uQnWhb3ndr8anOjipKLw

my %hint = (
    columns => [
        'type',
        'subtype',
        'name',
        'file_size',
        'sha1hash',
        'sha256hash',
        'path',
        'default_path'
    ],
);

sub json_hint {
    return \%hint;
}

1;
