package C4::Biblio;
# Test double: ModBiblio writes the record to the state folder (fails with
# "modbiblio.fail"); the framework comes from "biblio/<n>.fw".
use strict;
use warnings;
use Exporter 'import';
use Encode qw( encode );
use KeiKohaState;
our @EXPORT_OK = qw( ModBiblio GetFrameworkCode GetMarcFromKohaField );
sub GetMarcFromKohaField { return $_[0] eq 'items.itemnumber' ? ( '952', '9' ) : () }
sub GetFrameworkCode { my $fw = KeiKohaState::slurp( KeiKohaState::path("biblio/$_[0].fw") ) // ''; chomp $fw; return $fw }
sub ModBiblio {
    my ( $record, $biblionumber, $frameworkcode ) = @_;
    KeiKohaState::note( 'ModBiblio', $biblionumber, "fw=$frameworkcode", 'tags=' . join( ',', map { $_->tag } $record->fields ) );
    return 0 if -e KeiKohaState::path('modbiblio.fail');
    open( my $fh, '>:raw', KeiKohaState::path("biblio/$biblionumber.xml") ) or die $!;
    print {$fh} encode( 'UTF-8', $record->as_xml_record('MARC21') );
    close $fh;
    return 1;
}
1;
