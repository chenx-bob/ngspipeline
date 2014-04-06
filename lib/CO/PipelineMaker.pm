package CO::PipelineMaker;

# this module handles dependency of each steps,
# adds codes to check whether each step run successfully,
# adds some statistics of each step
# Now, it only supports PBS system

use strict;

use Cwd;
use File::Spec;
use CO::Utils;
use Term::ANSIColor;

our $VERSION = "0.0.1";

sub new {
	my $class = shift;
	$class = ref($class) ? ref($class) : $class;
	
	my %conf = @_;
	
	$conf{dir} = $conf{dir} ? $conf{dir} : getcwd();
	-e $conf{dir} ? 1 : mkdir($conf{dir}), 0775 || die "cannot create $conf{dir} with mode 0775\n";
	
	my $d = {dir            => $conf{dir},                   # job dir
	         log_dir        => "$conf{dir}/ngs_log",         # log dir for message from cluster
	         qsub_dir       => "$conf{dir}/ngs_qsub",        # shell scripts for qsub
	         tmp_dir        => "$conf{dir}/ngs_tmp",         # temporary dir for the job
			 flag_dir       => "$conf{dir}/ngs_flag",        # flag dir flagging whether jobs have been successfully finished
	         report_dir     => "$conf{dir}/ngs_report",      # some reports generated by NGS tools
	         job_name       => undef,                        # name for the current step in pipeline
	         job_dependency => undef,                        # denpendency for the current step in pipeline
			 enforce        => 0,                            # whether to ignore the flags
			 do_test        => 0,
			 filesize       => 1024*1024,
			 prefix         => "",
			 email          => 'z.gu@dkfz.de',
	         @_};

	-e "$d->{log_dir}"    ? 1 : mkdir("$d->{log_dir}"),    0775 || die "cannot create $d->{log_dir} with mode 0775\n";
	-e "$d->{qsub_dir}"   ? 1 : mkdir("$d->{qsub_dir}"),   0775 || die "cannot create $d->{qsub_dir} with mode 0775\n";
	-e "$d->{tmp_dir}"    ? 1 : mkdir("$d->{tmp_dir}"),    0775 || die "cannot create $d->{tmp_dir} with mode 0775\n";
	-e "$d->{flag_dir}"   ? 1 : mkdir("$d->{flag_dir}"),   0775 || die "cannot create $d->{flag_dir} with mode 0775\n";
	-e "$d->{report_dir}" ? 1 : mkdir("$d->{report_dir}"), 0775 || die "cannot create $d->{report_dir} with mode 0775\n";

	$d->{log_dir}    = to_abs_path($d->{log_dir});	
	$d->{qsub_dir}   = to_abs_path($d->{qsub_dir});
	$d->{tmp_dir}    = to_abs_path($d->{tmp_dir});
	$d->{flag_dir}   = to_abs_path($d->{flag_dir});
	$d->{report_dir} = to_abs_path($d->{report_dir});
	
	$d->{prefix}     = $d->{prefix} ? "$d->{prefix}_" : "";
	
	# log file for current pipeline
	$d->{ngspipeline_log_file} = "$d->{report_dir}/ngspipeline_log_file_".time.".txt";

	return bless $d, $class;
}

# if $add_tag is ture, then it will check the exit code as well as the running time for the command
# there are several conditions that a job failed:
# 1. the job returns a failed flag (non-zero value and die signal)
# 2. exit normally and print some error message
# for the first condition, it is easy for PBS system to catch the error but for
# the second condition, it is difficult.
sub add_command {
	my $self = shift;
	my $command = shift;
	my $add_tag = shift;
	$add_tag = defined($add_tag) ? $add_tag : 1;  # whether to check the status of this command
	
	# initialize command array reference
	if(! exists($self->{command})) {
		$self->{command} = [];
	}
	
	my $fn = $self->get_job_name;
	# if checking the status of the command, we will add additional commands
	if($add_tag) {
		# add information before the command
		push(@{$self->{command}}, "
time1=`date +%s`
echo [$fn] Start: `date` >> $self->{ngspipeline_log_file}
echo \"[$fn] Command: $command\" >> $self->{ngspipeline_log_file}
");
		
		# escape double quote
		$command =~s/"/\"/g;
		
		# eval the command, catch the error
		$command = "
$command
if [ \$? -ne 0 ]
then
	echo [$fn] Exit code is not equal to zero. There is an error. >> $self->{ngspipeline_log_file}
    exit 123
fi";
	}
	
	push(@{$self->{command}}, $command);
	
	if($add_tag) {
		# add information after the command, calculate how long it takes.
		push(@{$self->{command}}, "
time2=`date +\%s`
echo [$fn] End: `date` >> $self->{ngspipeline_log_file}
echo [$fn] Time: \$(( \$time2 - \$time1)) s >> $self->{ngspipeline_log_file}
		");
	
	}
}


# run a step in the pipeline
sub run {
	my $self = shift;
	
	
	my %qsub_settings = (
        "-j" => "oe",
        "-M" => $self->{email},
        "-o" => $self->{log_dir},
        @_
    );
    
    my $fn = $qsub_settings{'-N'} || $self->get_job_name;
	# when all command in a step succeed, add a flag file for this step
    $self->add_command("touch $self->{flag_dir}/$fn.success.flag", 0); # assume there is no error with deleting files
    
    my $command = $self->{command};
	
	# the job has been successfully finished, no need to run, empty the command stack
	if(!$self->{enforce} and -e "$self->{flag_dir}/$fn.success.flag") {
		print colored ("  [skip] $fn", "bold green"), "\n";
		$self->{command} = [];
		$self->set_job_dependency(undef);
		$self->set_job_name(undef);
		return undef;
		
	} else {
	
		if($self->{enforce}) {
			unlink("$self->{flag_dir}/$fn.success.flag") if(-e "$self->{flag_dir}/$fn.success.flag");
		}
		
		my $sh = $fn."_".time().int(rand(99999));
		open SH, ">$self->{qsub_dir}/$sh.sh" or die "Cannot create $self->{qsub_dir}/$sh.sh";
		
		# we have already used -N option, in $fh
		if(exists($qsub_settings{'-N'})) {
			delete($qsub_settings{'-N'});
		}
		# we don't need the explicit -W, denpendency are dealed automatically
		if(exists($qsub_settings{'-W'})) {
			delete($qsub_settings{'-W'});
		}
	
		print SH "#!/bin/sh\n";
		print SH "#PBS -N $self->{prefix}$fn\n";
		foreach my $k (keys %qsub_settings) {
			if(ref($qsub_settings{$k}) eq "HASH") {
				foreach my $opt (keys %{$qsub_settings{$k}}) {
					print SH "#PBS $k $opt=$qsub_settings{$k}->{$opt}\n";
				}
			} else {
				print SH "#PBS $k $qsub_settings{$k}\n";
			}
		}

		# -q options
		#if(!defined($qsub_settings{'-q'})) {
		#	my $walltime = $qsub_settings{'-l'}->{walltime} || "1:00:00";
		#	my ($h, $m, $s) = split ":", $walltime;
		#	$h += 0; $m += 0; $s += 0;
		#	if($h == 0 and $m + $s/60 <= 20) {
		#		print SH "#PBS -q fast\n";
		#	} elsif($h + $m/60 + $s/3600 <= 2) {
		#		print SH "#PBS -q medium\n";
		#	} elsif($h + $m/60 + $s/3600 <= 12) {
		#		print SH "#PBS -q long\n";
		#	} else {
		#		print SH "#PBS -q verylong\n";
		#	}
		#}
		
		# if there is denpendency
		if($self->get_job_dependency) {
			print SH "#PBS -W depend=afterok:".$self->get_job_dependency."\n";
		}
		
		# first print the job name and then all command in this job
		print SH "\n";
		print SH "echo [$fn] Job: $fn >> $self->{ngspipeline_log_file}\n";
		print SH "cd $self->{dir}\n\n\n";
		print SH join "\n", @$command;
		print SH "\n";
		close SH;
		
		# empty the command array
		$self->{command} = [];
		$self->set_job_dependency(undef);
		$self->set_job_name(undef);
		
		print "  - $fn\n";
		
		# finally call qsub
		my $qid;
		my $res;
		if($self->{do_test}) {
			$qid = int(rand(10000));
		} else {
			$res = `qsub $self->{qsub_dir}/$sh.sh`;
			if($res =~/^(\d+)/) {
				$qid = $1;
			} else {
				$qid = undef;
			}
		}
		
		return $qid;
	}
}

# first test whether this file exists
sub del_file {
	my $self = shift;
	foreach (@_) {
		$self->add_command("if [ -f $_ ];then\n echo delete $_\n rm -r $_\nfi\n", 0);
	}
}


###################################################################################
# if errors happen in some programmes, they will not throw error code to the shell 
# So we need to think out some other way to detect the error.
# Normally, in NGS pipeline, the output file are extremely large, so if the output
# file is unexpectedly small, then there woule be an error.
sub check_filesize {
	my $self = shift;
	my $file = shift;
	my $size = shift || $self->{filesize};
	
	my $fn = $self->get_job_name;
	
	if($size) {
	
		$self->add_command("
if [ ! -f $file ]
then
  echo [$fn] 'cannot find $file, maybe upstreaming steps failed.' >> $self->{ngspipeline_log_file}
  exit 123
fi

s=`du -b $file | awk '{print \$1}'`
if [ \$s -lt $size ]
then
  echo \"[$fn] your output file ($file: \$s Byte) is too small. I am quite sure something wrong happened.\" >> $self->{ngspipeline_log_file}
  exit 123
fi
", 0);
	}
}

sub set_job_name {
	my $self = shift;
	
	$self->{job_name} = shift;
}

sub set_job_dependency {
	my $self = shift;
	my @qid = grep {defined($_) } @_;
	
	$self->{job_dependency} = join ":", @qid;
}

sub get_job_name {
	my $self = shift;
	
	return($self->{job_name});
}

sub get_job_dependency {
	my $self = shift;
	
	return($self->{job_dependency});
}

1;
