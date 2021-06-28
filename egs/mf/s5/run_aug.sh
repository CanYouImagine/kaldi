#!/bin/bash

# Copyright 2018 Beijing MoMo Tech. Co. Ltd. (Authors: Zhiyong Yan)

#data=/data/yanzhiyong/my_work/am_train/data
echo ===========================================
echo $(date)
echo ===========================================

export rootdir=`pwd .`
export datadir=$rootdir/data_noise
#export trainset=train_tmp
#export traindatadir=$datadir/$trainset
export langdir=$datadir/lang
export langchaindir=$datadir/lang_chain
export fbankdir=/data/ma.fei/fbank
#export fbank80dir=$rootdir/fbank80
export mfccdir=/data/ma.fei/mfcc
export expdir=$rootdir/exp_noise

#export trainmfccdir=$datadir/${trainset}_mfcc

export gmmdir=$expdir/tri6b
export gmmalidir=$expdir/tri6b_ali_combined
export treedir=$expdir/tri6b_ali_convert_tree
export gmmlatsdir=$expdir/tri6b_lats_combined
export chaininitdir=$expdir/chain/tdnn_init

alignment_subsampling_factor=1

. ./cmd.sh 
. ./path.sh

train_sets="aishell_960h aishell_960h_noise aishell_960h_sp1.1 aishell_960h_sp1.1_noise chatroom_4500h"

stage=17
train_nj=20

if [ $stage -le -1 ]; then
  # Lexicon Preparation
  local/momo_prepare_dict.sh resource/lexicon_cvte.txt data/local/dict || exit 1;
  # Phone Sets, questions, L compilation
  
  utils/prepare_lang.sh --position-dependent-phones false data/local/dict "SIL" data/local/lang data/lang || exit 1;
  cp data/lang/words.txt conf/
fi

if [ $stage -le 0 ]; then
  
  echo "rm oov for train"
  local/rm_oov_from_feat.pl $traindatadir conf/words.txt > $traindatadir/wav_.scp
	mv $traindatadir/wav_.scp $traindatadir/wav.scp
  echo "fix data dir"
  utils/fix_data_dir.sh $traindatadir

fi

# volume perturb
if [ $stage -le -1 ]; then
  for train_set in $train_sets; do
    ./utils/data/perturb_data_dir_volume.sh $datadir/$train_set || exit 1;
  done
fi

# Now make mfcc features.
# mfccdir should be some place with a largish disk where you want to store mfcc features.
if [ $stage -le 12 ]; then
  for train_set in ${train_sets}; do
    if [ ! -e $datadir/${train_set}_mfcc/feats.scp ]; then
      echo "extract mfcc ${train_set}_mfcc"
      steps/make_mfcc_pitch.sh --cmd "run.pl" --nj 20 $datadir/${train_set}_mfcc $mfccdir/log $mfccdir || exit 1;
      steps/compute_cmvn_stats.sh $datadir/${train_set}_mfcc $mfccdir/log $mfccdir || exit 1;
      utils/fix_data_dir.sh $datadir/${train_set}_mfcc || exit 1;
    fi
  done
  echo "mfcc extract finish"
fi

#mfcc feature gmm ali
if [ $stage -le -13 ]; then
  for train_set in $train_sets; do
    if [ ! -e ${expdir}/tri6b_ali_$train_set ]; then
      echo "ali $train_set"
      steps/align_fmllr.sh --cmd $train_cmd --nj $train_nj  $datadir/${train_set}_mfcc $langdir $gmmdir ${expdir}/tri6b_ali_$train_set || exit 1;
    fi
    if [ ! -e ${expdir}/tri6b_lats_$train_set ]; then
      echo "lats $train_set"
      steps/align_fmllr_lats.sh --cmd $train_cmd --nj $train_nj $datadir/${train_set}_mfcc $langdir $gmmdir $expdir/tri6b_lats_$train_set || exit 1;
    fi
  done
  echo "stage 3 done"
fi

# copy alignment
if [ $stage -le 13 ]; then
  echo "copy aliment for noise data"
  cleandata="aishell_960h aishell_960h_sp1.1"
  for train_set in $cleandata; do
    ./steps/copy_ali_dir.sh --prefix "noise" --suffix ""  $datadir/${train_set}_noise_mfcc $expdir/tri6b_ali_${train_set} $expdir/tri6b_ali_${train_set}_noise || exit 1; 
    ./steps/copy_lat_dir.sh --prefix "noise" --suffix ""  $datadir/${train_set}_noise_mfcc $expdir/tri6b_lats_${train_set} $expdir/tri6b_lats_${train_set}_noise || exit 1;
  done
fi

if [ $stage -le -14 ]; then
  for train_set in ${train_sets}; do
    if [ ! -e $datadir/${train_set}_fbank80/feats.scp ]; then
      echo "extract fbank feature $train_set "
      steps/make_fbank.sh --cmd $train_cmd --nj $train_nj --fbank-config conf/fbank80.conf $datadir/${train_set}_fbank80 $fbankdir/log $fbankdir || exit 1;
      steps/compute_cmvn_stats.sh $datadir/${train_set}_fbank80 $fbankdir/log $fbankdir|| exit 1;
      utils/fix_data_dir.sh $datadir/${train_set}_fbank80 || exit 1;
    fi
  done

fi

if [ $stage -le 15 ]; then
  for train_set in $train_sets; do
    mfccdatastr+="$datadir/${train_set}_mfcc "
    fbankdatastr+="$datadir/${train_set}_fbank80 "
    alidir+="$expdir/tri6b_ali_${train_set} "
    latdir+="$expdir/tri6b_lats_${train_set} "
  done
  if [ ! -e $datadir/combined_data ]; then
    echo "combine data!"
    #./utils/combine_data.sh $datadir/combined_data_mfcc $mfccdatastr || exit 1;
    #./utils/fix_data_dir.sh $datadir/combined_data_mfcc || exit 1;
    #./utils/combine_data.sh $datadir/combined_data_fbank $fbankdatastr || exit 1;
    #./utils/fix_data_dir.sh $datadir/combined_data_fbank || exit 1;
  fi
  if [ ! -e $gmmalidir ]; then
    echo "combine ali"
    ./steps/combine_ali_dirs.sh --nj 20 $datadir/combined_data_mfcc $gmmalidir $alidir || exit 1;
    cp -rf $gmmdir/*_opts $gmmalidir/
    cp -rf $gmmdir/*.mat $gmmalidir/
  fi
  if [ ! -e $gmmlatsdir ]; then
    echo "combine lats"
    ./steps/combine_lat_dirs.sh --nj 20 $datadir/combined_data_mfcc $gmmlatsdir $latdir || exit 1;
  fi
fi

#convert ali to new tree
if [ $stage -le 16 ]; then
  mkdir -p $treedir $treedir/log
  cp $gmmalidir/splice_opts $treedir 2>/dev/null # frame-splicing options.
  cp $gmmalidir/cmvn_opts $treedir 2>/dev/null # cmn/cmvn option.
  cp $gmmalidir/delta_opts $treedir 2>/dev/null # delta option.
  cp $langchaindir/phones.txt $treedir || exit 1;
  nj=`cat $gmmalidir/num_jobs` || exit 1;
  echo $nj >$treedir/num_jobs
  cp $gmmalidir/final.mat $treedir
  cp $gmmalidir/full.mat $treedir
  cp $chaininitdir/final.mdl $treedir
  cp $chaininitdir/tree $treedir
  $train_cmd JOB=1:$nj $treedir/log/convert.JOB.log \
    convert-ali --repeat-frames=false --frame-subsampling-factor=$alignment_subsampling_factor \
    $gmmalidir/final.mdl $chaininitdir/final.mdl $treedir/tree \
    "ark:gunzip -c $gmmalidir/ali.JOB.gz|" "ark:|gzip -c >$treedir/ali.JOB.gz" || exit 1;
        echo "stage 6 done"
fi

dir=$expdir/chain/tdnnf_fbank80_full_data
#train chain model by gmm ali
if [ $stage -le 17 ]; then
  local/chain/run_momo_tdnnf_20layers.sh --stage 10  --train_stage -10 --iter_init 0 --num_epochs 4 --num_jobs_final 8 \
    $dir $datadir/combined_data_fbank $treedir $gmmlatsdir
  echo "chain model train finished"
fi

