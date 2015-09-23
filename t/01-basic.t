use v6;
use Test;
use HTTP::MultipartParser;

my $fh = open 't/dat/002-content.dat', :bin;

my $parts;
my $parser = HTTP::MultipartParser.new(
    boundary => 'LYNX'.encode('ascii'),
    on_header => sub ($h) {
    },
    on_body => sub ($body, $finished) {
        $parts++;
    },
);
loop {
    my $buf = $fh.read(1024);
    if $buf.bytes == 0 {
        $parser.finish;
        last;
    }
    $parser.add($buf);
}
is $parts, 9;

done-testing;

