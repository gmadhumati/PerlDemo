#!/usr/bin/perl
{

	package MyWebServer;

	use HTTP::Server::Simple::CGI;
	use base qw(HTTP::Server::Simple::CGI);
	our @ISA = qw(HTTP::Server::Simple::CGI);
	use CGI;
	use URI::Escape;
	use LWP::UserAgent;
	use HTTP::Request::Common;
	use LWP::Simple;
	use MIME::Base64;
	use GD::Graph::bars;
	use File::Fetch;
	$ua = LWP::UserAgent->new;

	my %dispatch = ( '/sequence' => \&process_html, );

	sub handle_request {
		my $self = shift;
		my $cgi  = shift;

		my $path    = $cgi->path_info();
		my $handler = $dispatch{$path};

		if ( ref($handler) eq "CODE" ) {
			print "HTTP/1.0 200 OK\r\n";
			$handler->($cgi);

		}
		else {
			print "HTTP/1.0 404 Not found\r\n";
			print $cgi->header,
			  $cgi->start_html('Not found'),
			  $cgi->h1('Not found'),
			  $cgi->end_html;
		}

	}

	sub process_html {

		my $cgi = shift;    # CGI.pm object
		return if !ref $cgi;

		print $cgi->header();

		# Output stylesheet, heading etc
		output_top($cgi);

		if ( $cgi->param() ) {

			# Parameters are defined, therefore the form has been submitted
			display_results($cgi);
		}
		else {
			# First time, display the form
			output_form($cgi);
		}

		# Output footer and end html
		output_end($cgi);

	}

	# Outputs the start html tag, stylesheet and heading
	sub output_top {
		my ($cgi) = @_;
		print $cgi->start_html(
			-title   => 'PerlDemo',
			-bgcolor => 'white',
			-style   => {
				-code => '
                    /* Stylesheet code */
                    body {
                        font-family: verdana, sans-serif;
                    }
                    h2 {
                        color: darkblue;                        
                    }
                    p {
                        color: darkblue;
                    }                    
                    div {
                        text-align: right;
                        color: steelblue;
                    }
                    th {
                        text-align: right;
                        padding: 2pt;
                        vertical-align: top;
                    }
                    td {
                        padding: 2pt;
                        vertical-align: top;
                    }
                    #submitButton {
						float:right;

                    }
                    #cancelButton {
                    	float:right;
                    }                    	
                    
                    
                    /* End Stylesheet code */
                ',
			},
		);
		print $cgi->h2("Histogram Plot of GC content of the top BLAST 10 hits of the input sequence");
	}

	# Outputs a footer line and end html tags
	sub output_end {
		my ($cgi) = @_;
		print $cgi->end_html;
	}

	# Displays the results of the form
	sub display_results {
		my ($cgi)        = @_;
		my $usersequence = $cgi->param('user_sequence');
		my $encoded_str  = blast_sequence($usersequence);

		print $cgi->img(
			{
				-src   => "data:image/png;base64,$encoded_str",
				-align => "center"
			}
		);

	}

	# Outputs a web form
	sub output_form {
		my ($cgi) = @_;
		print $cgi->start_form(
			-name   => 'main',
			-method => 'POST',
		);

		print $cgi->start_table;
		print $cgi->Tr(
			$cgi->td('Enter a FASTA sequence:'),
			$cgi->td(
				$cgi->textarea(
					-name => "user_sequence",
					-rows => 10,
					-cols => 100
				)
			)
		);

		print $cgi->Tr(
			$cgi->td('&nbsp;'),
			$cgi->td(
				$cgi->button( -value => 'Cancel', -id => 'cancelButton' ),
				$cgi->submit( -value => 'Submit', -id => 'submitButton' )

			),
			$cgi->td('&nbsp;')
		);
		print $cgi->end_table;
		print $cgi->end_form;
	}

	#sequence blast
	sub blast_sequence {

		$sequence      = shift;
		$encoded_query = '';
		$encoded_query = $encoded_query . uri_escape($sequence);

		$program  = "blastn";
		$database = "nr";

		# build the request
		$args =
		  "CMD=Put&PROGRAM=$program&DATABASE=$database&QUERY=" . $encoded_query;

		$req = new HTTP::Request POST =>
		  'http://www.ncbi.nlm.nih.gov/blast/Blast.cgi';
		$req->content_type('application/x-www-form-urlencoded');
		$req->content($args);

		# get the response
		$response = $ua->request($req);

		# parse out the request id
		$response->content =~ /^    RID = (.*$)/m;
		$rid = $1;

		# parse out the estimated time to completion
		$response->content =~ /^    RTOE = (.*$)/m;
		$rtoe = $1;

		# wait for search to complete
		sleep $rtoe;

		# poll for results
		while (true) {
			sleep 5;

			$req = new HTTP::Request GET =>
"http://www.ncbi.nlm.nih.gov/blast/Blast.cgi?CMD=Get&FORMAT_OBJECT=SearchInfo&RID=$rid";
			$response = $ua->request($req);

			if ( $response->content =~ /\s+Status=WAITING/m ) {

				#				print STDERR "Searching...\n";
				next;
			}

			if ( $response->content =~ /\s+Status=FAILED/m ) {
				print STDERR
"Search $rid failed; please report to blast-help\@ncbi.nlm.nih.gov.\n";
				exit 4;
			}

			if ( $response->content =~ /\s+Status=UNKNOWN/m ) {
				print STDERR "Search $rid expired.\n";
				exit 3;
			}

			if ( $response->content =~ /\s+Status=READY/m ) {
				if ( $response->content =~ /\s+ThereAreHits=yes/m ) {

					#  print STDERR "Search complete, retrieving results...\n";
					last;
				}
				else {
					print STDERR "No hits found.\n";
					exit 2;
				}
			}

			# if we get here, something unexpected happened.
			exit 5;
		}    # end poll loop

		# retrieve and display results
		$req = new HTTP::Request GET =>
"http://www.ncbi.nlm.nih.gov/blast/Blast.cgi?CMD=Get&FORMAT_TYPE=Text&RID=$rid";
		$response = $ua->request($req);

		@blast_output = split( "\n", $response->content );

		my @tophits_ids = '';
		my $i           = 0;
		my $c           = 0;
		$len_tophits_ids = 0;

		#retrieve ids of the top set of results
		foreach $blast_output_line (@blast_output) {
			chomp $blast_output_line;

			if ( $blast_output_line =~ m/^\w+\|(.*)\.\d+\|.*\d+/ ) {
				push( @tophits_ids, $1 );
				$len_tophits_ids = scalar @tophits_ids;
				if ( $len_tophits_ids > 11 ) {
					last;
				}

			}
		}

		my $file = get_fasta(@tophits_ids);

		my %gc = get_gc($file);
		$encoded_str = make_plot(%gc);
		return $encoded_str;

	}

	sub get_fasta {

		my (@acc_array) = @_;

		$acc_ids = join( "\,", @acc_array );
		$acc_ids =~ s/^,//;
		
		
		my $encode_ids = '';
		$encode_ids = $encode_ids . uri_escape($acc_ids);
		
		$base = 'http://eutils.ncbi.nlm.nih.gov/entrez/eutils/';
		$url  = $base
		  . 'efetch.fcgi?db=nuccore&id='.$encode_ids.'&rettype=fasta&retmode=text';

		my $fastaout = "tmpfasta.fa";
		getstore($url,$fastaout);

		return $fastaout;

	}

sub get_gc {

	($file) = @_;
	%seq_gc = ();
	open( INFASTA, $file ) || die "cannot open file\n";
	my @ids = '';

	$fline = <INFASTA>;
	if ( $fline =~ m/^>/ ) {
		@header = split( /\|/, $fline );
		$id = "'" . $header[3] . "'";
		my $seq = '';
		$flag = 0;
	}

	while (<INFASTA>) {
		chomp;
		if ( $_ =~ m/^>/ ) {
			@header = split( /\|/, $_ );
			$id = "'" . $header[3] . "'";
			my $seq = '';
			$flag = 1;
			

		}
		if ( $_ =~ m/^([ATGCN]+)$/ ) {
			$seq .= $1;			
			$flag = 0;
		}

		if ( $flag == 1 ) {
			
			$gccount = $totalcount = $gcount = $ccount = 0;

			$gcount = ($seq =~ s/G/G/g);
			$ccount = ($seq =~ s/C/C/g);
			$totalcount = length($seq);
			$gccount = $gcount + $ccount;
			if ( $totalcount > 0 ) {
				$gccontent = ( 100 * $gccount ) / $totalcount;
			}
			else {
				$gccontent = 0;
			}
			my $gccontent = sprintf( '%.2f', $gccontent );
			$seq_gc{$id} = $gccontent;	
			$seq = '';
		}
	}
	return %seq_gc;

}
	sub make_plot {

		my %gc = @_;

		my @xvalues = [ keys %gc ];
		my @y       = [ values %gc ];

		@data = (

			@xvalues,
			@y,
		);

		my $graph = GD::Graph::bars->new( 640, 480 );

		#creating a graph
		$graph->set_title_font(GD::gdGiantFont);
		$graph->set_text_clr("red");
		$graph->set_x_axis_font(GD::gdLargeFont);
		$graph->set_y_axis_font(GD::gdLargeFont);
		$graph->set_x_label_font(GD::gdGiantFont);
		$graph->set_y_label_font(GD::gdGiantFont);
		$graph->set(
			title             => "GC content",
			x_label           => "Sequences",
			y_label           => "Percent",
			y_max_value       => 0,
			y_max_value       => 100,
			bgclr             => "white",
			labelclr          => "black",
			textclr           => "green",
			axislabelclr      => "red",
			bar_spacing       => 5,
			x_labels_vertical => 1,

		) or die $graph->error;

		my $gd = $graph->plot( \@data ) or die $graph->error;

		my $IMG = '';
		$IMG     = $gd->gif;
		$encoded = encode_base64($IMG);

		return $encoded;
	}

}    # end of package MyWebServer

# start the server on port 8080
# my $pid = MyWebServer->new(8080)->background();
MyWebServer->new(8080)->run();

#print "Use 'kill $pid' to stop server.\n";

