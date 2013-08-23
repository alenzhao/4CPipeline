#!/usr/bin/perl


use strict;
use warnings;
use Getopt::Long;
use Carp;
use IO::File;
use Text::CSV;
use threads;
use Interpolation 'arg:@->$' => \&argument;
use Time::HiRes qw(gettimeofday tv_interval);

use Cwd qw(abs_path);
use FindBin;
use lib abs_path("$FindBin::Bin/../lib");

my $GENOME_DB = $ENV{'GENOME_DB'};
defined $GENOME_DB or croak "Error: set environment variable GENOME_DB";

require "PipelineHelper.pl";
require "Perlsub.pl";
require "pslHelper.pl";

# Flush output after every write
select( (select(STDOUT), $| = 1 )[0] );

##
## This program
## 
## run with "--help" for usage information
##
## Robin Meyers

# Forward declarations
sub parse_command_line;
sub read_in_meta_file;
sub check_existance_of_files;
sub process_experiment ($$);


# Global flags and arguments, 
# Set by command line arguments
my $meta_file;
my $indir;
my $outdir;
my $max_threads = 4;
my $userblatopt = "";
my $userblastopt = "";

# Global variabless
my %meta_hash;
my %stats; 
my $genome2bit;
my $defaultblatopt = "-mask=lower -minIdentity=95 -maxIntron=500";
my $defaultblastopt = "-task blastn-short -outfmt 6 -strand plus -gapopen 2 -gapextend 1 -reward 1 -penalty -2";

#
# Start of Program
#

parse_command_line;

my $t0 = [gettimeofday];

my $blatopt = manage_blat_options($defaultblatopt,$userblatopt);

my $blastopt = manage_blast_options($defaultblastopt,$userblastopt);

read_in_meta_file;

check_existance_of_files;



prepare_reference_genomes ($GENOME_DB, \%meta_hash);

my @threads = ();

foreach my $expt_id (sort keys %meta_hash) {

    while (1) {

    # joins any threads if possible
        foreach my $thr (@threads) {
            $thr->join() if $thr->is_joinable();
        }

        my @running = threads->list(threads::running);
        
        # if there are open threads, create a new one, push it onto list, and exit while loop
        if (scalar @running < $max_threads) {
            my $thr = threads->create( sub {
                        my $t0_expt = [gettimeofday];
                        print "\nStarting $expt_id\n";
                        unless (-d $meta_hash{$expt_id}->{exptdir}) {
                        	mkdir $meta_hash{$expt_id}->{exptdir} or croak "Error: cannot create experiment directory";
                        }
                        process_experiment($expt_id, $meta_hash{$expt_id} );
                        my $t1 = tv_interval($t0_expt);
                        printf("\nFinished %s in %.2f seconds.\n", $expt_id,$t1);
                    });
            push(@threads,$thr);
            sleep(1);
            last;
        }
        sleep(1);
    } 
}

# waits for all threads to finish
while( scalar threads->list(threads::all) > 0) {
    for my $thr (@threads) {
        $thr->join() if $thr->is_joinable;
    }
    sleep(1);
}

my $t1 = tv_interval($t0);

printf("\nFinished all processes in %.2f seconds.\n", $t1);


#
# End of program
#

sub process_experiment ($$) {

	my $expt_id = shift;
	my $expt_hash = shift;

	create_sequence_files ($expt_id,$expt_hash);

	blast_to_sequence_files($expt_id,$expt_hash,$blastopt);

	align_to_genome($expt_id,$expt_hash,$blatopt);

 	make_tlxl($expt_id,$expt_hash);

 	($expt_hash->{tlx} = $expt_hash->{tlxl}) =~ s/tlxl$/tlx/;

 	System(join(" ","Rscript $FindBin::Bin/../R/4CFilter.R",
 		$expt_hash->{tlxl},$expt_hash->{tlx},$expt_hash->{redrest},$expt_hash->{blurest}));

 	System(join(" ","tlxToBed.pl",$expt_hash->{tlx},"--bgbw --assembly",$expt_hash->{assembly}));


#	System("cp $expt_id->{tlxl}")
#	System("Rscript 4CFilter.R filter_reads;
}

sub read_in_meta_file {
	System("perl -pi -e 's/\\r/\\n/g' $meta_file");

	print "\nReading in meta file...\n";

	my $meta = IO::File->new("<$meta_file");
	my $csv = Text::CSV->new({sep_char => "\t"});
	my $header_ref = $csv->getline($meta);
	my @header = @$header_ref;
	$csv->column_names(@header);

	while (my $row = $csv->getline_hr($meta)) {
		my $expt_id = $row->{experiment}."_".$row->{seqrun};
		$meta_hash{$expt_id} = $row;
		$meta_hash{$expt_id}->{exptdir} = "$outdir/$expt_id";

	}
	#print join("\t",@header)."\n";
	#foreach my $expt (sort keys %meta_hash) {
	#	my $chr = $meta_hash{$expt}->{Chr};
	#	my $brksite = $meta_hash{$expt}->{Brksite};
	#	my $strand = $meta_hash{$expt}->{Strand};
	#	my %hash = %{$meta_hash{$expt}};
	#	print join("\t", @hash{@header} )."\n";
	#}

}

sub check_existance_of_files {
	print "\nSearching for files...\n";
	foreach my $expt_id (sort keys %meta_hash) {
		my $file = $indir."/".$expt_id;
		my @exts = qw(.fa .fasta .fq .fastq);
		foreach my $ext (@exts) {
			if (-r $file.$ext) {
				if ($ext =~ /q/) {
					(my $next = $ext) =~ s/q/a/;
					print "Converting $file to fasta format\n";
					System("fastq_to_fasta -Q33 -n -i $file$ext -o $file$next") or croak "Error: could not execute fastq_to_fastq";
					$meta_hash{$expt_id}->{raw} = $file.$next;
				} else {
					$meta_hash{$expt_id}->{raw} = $file.$ext;
				}
				last;
			}
		}
		croak "Error: Could not locate reads file $file in $indir" unless (defined $meta_hash{$expt_id}->{raw});
	}
	print "Done.\n";
}

sub parse_command_line {
	my $help;

	usage() if (scalar @ARGV == 0);

	my $result = GetOptions ( 
														"threads=i" => \$max_threads ,
														"blatopt=s" => \$userblatopt ,
														"blastopt=s" => \$userblastopt ,
														"help" => \$help

				            			);
	
	usage() if ($help);

	croak "Error: not enough input arguments" if (scalar @ARGV < 3);

	$meta_file = shift(@ARGV);
	$indir = shift(@ARGV);
	$outdir = shift(@ARGV);

  #Check options

  croak "Error: cannot find $meta_file" unless (-r $meta_file);
  croak "Error: input directory $indir does not exist" unless (-d $indir);
  unless (-d $outdir) {
  	System("mkdir -p $outdir") or croak "Error: output directory $outdir does not exist and cannot be created";
  }



	exit unless $result;
}


sub usage()
{
print<<EOF;
Title, by Robin Meyers, ddmonthyyyy

This program .


Usage: $0 arg1 arg2 arg3 ...
        [--option VAL] [--flag] [--help]

Arguments (defaults in parentheses):

$arg{"metafile","File containing meta data for one experiment per row - follow correct format"}
$arg{"indir","Directory containing all input sequence files"}
$arg{"outdir","Directory for results files"}
$arg{"--threads","Number of threads to run bowtie on","$max_threads"}
$arg{"--blatopt","",$defaultblatopt}
$arg{"--blastopt","",$defaultblastopt}
$arg{"--help","This helpful help screen."}


EOF

exit 1;
}
