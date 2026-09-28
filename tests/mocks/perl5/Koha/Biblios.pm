package Koha::Biblios;
# Test double: a record exists when biblio/<n>.xml does; "biblio/<n>.items"
# holds its number of items.
use strict;
use warnings;
use Encode qw( decode );
use MARC::Record;
use MARC::File::XML ( BinaryEncoding => 'utf8', RecordFormat => 'USMARC' );
use KeiKohaState;
sub find {
    my ( $class, $biblionumber ) = @_;
    my $xml = KeiKohaState::slurp( KeiKohaState::path("biblio/$biblionumber.xml") );
    return unless defined $xml;
    my $r = MARC::Record->new_from_xml( $xml, 'UTF-8', 'MARC21' );
    my $items = KeiKohaState::slurp( KeiKohaState::path("biblio/$biblionumber.items") ) // 0;
    return bless { r => $r, items => $items + 0 }, 'KeiBiblio';
}
package KeiBiblio;
sub title  { my $f = $_[0]{r}->field('245'); return $f ? $f->subfield('a') : '' }
sub author { my $f = $_[0]{r}->field('100'); return $f ? $f->subfield('a') : undef }
sub items  { my $n = $_[0]{items}; return bless { n => $n }, 'KeiItems' }
package KeiItems;
sub count { return $_[0]{n} }
1;
