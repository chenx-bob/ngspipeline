#!/bin/perl/bin/

# load neccessary modules
# put ./lib into @INC
BEGIN {
	use File::Basename;
	unshift(@INC, dirname($0)."/lib");
}


use strict;

# general modules that should be loaded
use CO::PipelineMaker;
use File::Basename;
use CO::NGSPipeline::Getopt;   # validate command-line arguments

# pipeline modules
use CO::NGSPipeline::Pipeline::Bismark;
use CO::NGSPipeline::Pipeline::BSMAP;
use CO::NGSPipeline::Pipeline::methylCtools;

# command line options
my $opt = CO::NGSPipeline::Getopt->new;

$opt->before("
WGBS pipeline.

USAGE:

  perl $0 --list file --dir dir --tool tool
  perl $0 --list file --dir dir --tool tool --no-bissnp
  perl $0 --list file --dir dir --tool tool --enforce
  perl $0 --list file --dir dir --tool tool --sample s1,s2
  
");

$opt->after("
NOTE:
  If your fastq files are stored in the standard directory structure which
are generated by data management group, use get_sample_list_from_std_dir.pl
first to generate sample list file.

  Since methylCtools uses BWA to do alignment, about 20% alignment jobs will be
sent to Convey.

FEATURES:
  - record running time for every command
  - catch errors both from exit code and output file size
  - re-run pipeline while skip the upsteam successful jobs
  - generate a detailed QC report

");

# default values, also defined in CO::PipelineMaker
my $wd        = "analysis";
my $tool      = "bsmap";
my $list;
my $enforce   = 0;
my $request_sampleid;
my $no_bissnp = 0;   # by default to use bissnp
my $do_test   = 0;
my $filesize  = 1024*1024;   # at least output file size should larger than 1M, this value can be overwrite inside each step (Tool:: modules)
my $prefix    = "";
my $email     = 'z.gu@dkfz.de';
my $species   = 'human';

# common arguments
$opt->add(\$list,             "list=s");
$opt->add(\$wd,               "dir=s");
$opt->add(\$tool,             "tool=s",
                              "available tools: bsmap, (bismark, methyctools still have bugs)");
$opt->add(\$enforce,          "enforce!");
$opt->add(\$request_sampleid, "sample=s");
$opt->add(\$do_test,          "test!");
$opt->add(\$filesize,         "filesize=i");
$opt->add(\$prefix,           "prefix=s");
$opt->add(\$email,            "email=s");
$opt->add(\$species,          "species=s",
	                          "human (default) or mouse");

# specific arguments for WGBS pipeline
$opt->add(\$no_bissnp,        "nobissnp!",
                              "whether use BisSNP or methylation calling script of each tool to do methylation calling. There is QC report only if you use BisSNP. By default, the three pipelines use BisSNP.");

# parse command line arguments, validate sample list file and transform
$opt->getopt;

# $list is like:
# $list->{sample_id}->{r1} = [lane1.r1, lane2.r1, ...]
# $list->{sample_id}->{r1} = [lane1.r2, lane2.r2, ...]

foreach my $sample_id (sort keys %$list) {
	
	print "=============================================\n";
	print "submit pipeline for $sample_id\n";
	
	# initialize specific pipeline;
	my $pipeline;
	if($tool eq "bismark") {
	
		$pipeline = CO::NGSPipeline::Pipeline::Bismark->new();
		
	} elsif($tool eq "bsmap") {
	
		$pipeline = CO::NGSPipeline::Pipeline::BSMAP->new();
		
	} elsif($tool eq "methylctools") {
	
		$pipeline = CO::NGSPipeline::Pipeline::methylCtools->new();
		
	} else {
		die "--tool can only be set to one of 'bismark', 'bsmap' and 'methylctools'.\n";
	}
	
	my $r1      = $list->{$sample_id}->{r1};            # array reference, r1 lanes for this sample
	my $r2      = $list->{$sample_id}->{r2};            # array reference, r2 lanes for this sample
	my $library = $list->{$sample_id}->{library};
	
	# send PipelineMaker object to the pipeline
	my $pm = CO::PipelineMaker->new(dir      => "$wd/$sample_id",
	                                enforce  => $enforce,
									do_test  => $do_test,
									filesize => $filesize,
									prefix   => $prefix,
									email    => $email,);
	
	$pipeline->set_pipeline_maker($pm);
	
	# passing specific parameters for the pipeline
	$pipeline->run(sample_id => $sample_id,
                   r1        => $r1,
                   r2        => $r2,
                   library   => $library,
                   no_bissnp => $no_bissnp,
                   species   => $species,
                  );
		
}

