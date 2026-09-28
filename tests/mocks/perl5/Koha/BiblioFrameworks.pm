package Koha::BiblioFrameworks;
# Test double: the default framework and two others.
use strict;
use warnings;
sub search { return bless {}, 'KeiFrameworkSet' }
package KeiFrameworkSet;
sub as_list { return map { bless $_, 'KeiFramework' } ( { code => '', text => 'Default' }, { code => 'FA', text => 'Livros' }, { code => 'SER', text => 'Seriados <i>' } ) }
package KeiFramework;
sub frameworkcode { return $_[0]{code} }
sub frameworktext { return $_[0]{text} }
1;
