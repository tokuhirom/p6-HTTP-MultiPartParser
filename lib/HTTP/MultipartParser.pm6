use v6;
unit class HTTP::MultiPartParser;

# https://github.com/chansen/p5-http-multipartparser/blob/master/lib/HTTP/MultiPartParser.pm

constant DEBUGGING = %*ENV<MULTIPART_DEBUGGING>.Bool;

macro debug($message) {
    if DEBUGGING {
        quasi {
            say "[DEBUG] [{$*THREAD.id}] " ~ {{{$message}}};
        }
    } else {
        quasi { }
    }
}

my enum State <PREAMBLE BOUNDARY HEADER BODY DONE EPILOGUE>;

constant CRLF = Blob.new(0x0d, 0x0a);
constant HYPENHYPEN = "--".encode('ascii');

has State $!state = PREAMBLE;
has Blob $.boundary;
has Blob $!buffer .= new;
has Sub $.on_header is required;
has Sub $.on_error = sub ($err) { die($err) };
has Sub $.on_body is required;
has Bool $!finish = False;

has int $.max_header_size = 32768;

has Blob $!boundary-begin = HYPENHYPEN ~ self.boundary;
has Blob $!boundary-end   = self.boundary ~ HYPENHYPEN;

has Blob $!delimiter-begin = CRLF ~ $!boundary-begin;
has Blob $!delimiter-end = CRLF ~ $!boundary-end;

has Blob $!boundary-delimiter = CRLF ~ HYPENHYPEN ~ self.boundary;

# I need Blob#index(Blob)
my multi sub index(Blob $buffer, Blob $substr) {
    my $i = 0;
    my $l = $buffer.bytes;
    while ($i < $l) {
        if ($buffer.subbuf($i, $substr.bytes) eq $substr) {
            return $i;
        }
        ++$i;
    }
    return -1; # not found
}

method !parse_preamble() {
    my int $index = index($!buffer, $!boundary-begin);
    if ( $index < 0 ) {
        return False;
    }

    # replace preamble with CRLF so we can match dash-boundary as delimiter
    $!buffer = $!buffer.subbuf($index + 2 + $.boundary.bytes);

    $!state = BOUNDARY;

    return True;
}

method !parse_boundary() returns Bool {
    if ($!buffer.bytes < 2) {
        $!finish && $.on_error.(q/End of stream encountered while parsing boundary/);
        return False;
    } elsif ($!buffer.subbuf(0, 2) eq CRLF) {
        $!buffer = $!buffer.subbuf(2);
        $!state = HEADER;
        return True;
    } elsif ($!buffer.subbuf(0, 2) eq HYPENHYPEN) {
        if ($!buffer.bytes < 4) {
            $!finish && $.on_error.(q/End of stream encountered while parsing closing boundary/);
            return False;
        } elsif ($!buffer.subbuf(2, 2) eq CRLF) {
            $!buffer = $!buffer.subbuf(4);
            $!state = EPILOGUE;
            return True;
        } else {
            $.on_error.(q/Closing boundary does not terminate with CRLF/);
            return False;
        }
    }
    else {
        $.on_error.(q/Boundary does not terminate with CRLF or hyphens/);
        return False;
    }
}

method !parse_header() {
    my $index = index( $!buffer, CRLF ~ CRLF);
    if ($index < 0) {
        if ($!buffer.bytes > $.max_header_size) {
            $.on_error.(q/Size of part header exceeds maximum allowed/);
            return False;
        }
        $!finish && $.on_error.(q/End of stream encountered while parsing part header/);
        return False;
    }

    my $header = $!buffer.subbuf(0, $index).decode('ascii');
    $!buffer = $!buffer.subbuf( $index + 4 );

    my @headers;
    for $header.split(/\r\n/) {
        if $_ ~~ /^<[ \t]>+(.*)$/ {
            @headers[*-1] ~= $/[0];
        } else {
            @headers.push($_);
        }
    }

#   my regex field-name { ^ <-[\x00..\x1f \x7f ()<>@,;:\\"\/?={} \t]>+? }

#   my @results;

#   for @headers -> $header {
#       if $header ~~ /^(<field-name>)<[\t ]>*\:<[\t ]>*(.*?)$/ {
#           @results.push(($/[0].Str.lc => $/[1].Str.trim));
#       } else {
#           $.on_error.("Malformed header line");
#       }
#   }
    $.on_header.(@headers);

    $!state = BODY;

    return True;
}

method finish() {
    $!finish = True;
    self.parse();
}

method !parse_body() {
    my $take = index($!buffer, $!boundary-delimiter);
    if ($take < 0) {
        $take = $!buffer.bytes - (6 + $.boundary.bytes);
        if ($take <= 0) {
            $!finish && $.on_error.(q/End of stream encountered while parsing part body/);
            return False;
        }
    } else {
        $!state = BOUNDARY;
    }

    my $chunk = $!buffer.subbuf(0, $take);
    $!buffer = $!buffer.subbuf($take);

    if ($!state == BOUNDARY) {
        $!buffer = $!buffer.subbuf(4 + $.boundary.bytes);
    }

    $.on_body.($chunk, $!state == BOUNDARY);
    return True;
}

# RFC 2616 3.7.2 Multipart Types
# Unlike in RFC 2046, the epilogue of any multipart message MUST be
# empty; HTTP applications MUST NOT transmit the epilogue (even if the
# original multipart contains an epilogue). These restrictions exist in
# order to preserve the self-delimiting nature of a multipart message-
# body, wherein the "end" of the message-body is indicated by the
# ending multipart boundary.
method !parse_epilogue() {
    if $!buffer.bytes != 0 {
        $.on_error.(q/Nonempty epilogue/);
    }
    return False;
}

method parse() {
    loop {
        debug($!state);

        given $!state {
            when PREAMBLE {
                return unless self!parse_preamble
            }
            when BOUNDARY {
                return unless self!parse_boundary
            }
            when HEADER {
                return unless self!parse_header
            }
            when BODY {
                return unless self!parse_body
            }
            when EPILOGUE {
                return unless self!parse_epilogue
            }
            default { die "Illegal state" }
        }
    }
}

method add(Buf $buf) {
    $!buffer ~= $buf;
    self.parse();
}

=begin pod

=head1 NAME

HTTP::MultiPartParser - low level multipart/form-data parser

=head1 SYNOPSIS

  use HTTP::MultiPartParser;

=head1 DESCRIPTION

HTTP::MultiPartParser is low level multipart/form-data parser library.

This library is port of chansen's HTTP::MultiPartParser for Perl5.

=head1 COPYRIGHT AND LICENSE

    Copyright 2015 Tokuhiro Matsuno <tokuhirom@gmail.com>

    This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

And oritinal perl5's HTTP::MutlipartParser is

    Copyright 2012-2013 by Christian Hansen.

    This is free software; you can redistribute it and/or modify it under the same terms as the Perl 5 programming language system itself.

=end pod
