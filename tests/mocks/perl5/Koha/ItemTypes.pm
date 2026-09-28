package Koha::ItemTypes;
# Test double: two item types.
use strict;
use warnings;
sub search { return bless {}, 'KeiItemTypesSet' }
package KeiItemTypesSet;
sub as_list { return map { bless $_, 'KeiItemType' } ( { itemtype => 'LIVRO', description => 'Livro' }, { itemtype => 'REV', description => 'Revista <b>' } ) }
package KeiItemType;
sub itemtype    { return $_[0]{itemtype} }
sub description { return $_[0]{description} }
1;
