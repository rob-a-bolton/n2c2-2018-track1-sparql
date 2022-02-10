# n2c2-2018-track1-sparql
Small pipeline to perform some basic cohort identification on n2c2 2018 track1 data using SPARQL

# Setup
Clone the repo recursively with `git clone --recursive https://github.com/rob-a-bolton/n2c2-2018-track1-sparql.git` and change into that directory.  
Download the [n2c2 2018 Track 1: Cohort Selection for Clinical Trials](https://portal.dbmi.hms.harvard.edu/projects/n2c2-2018-t1/) data and unzip the files into the data directory.  
At this point, `data/` should contain both `train/` and `n2c2-t1_gold_standard_test_data/` directories. `train/` should contain numbered patient XML files and `n2c2-t1_gold_standard_test_data` should contain `n2c2-t1_gold_standard_test_data/test`, which contains its own patient XML files.  

