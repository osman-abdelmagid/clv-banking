# Raw data

Put the eight PKDD'99 "Berka" files here, unchanged:

    account.csv  card.csv  client.csv  disp.csv  district.csv  loan.csv  order.csv  trans.csv

Source: the PKDD'99 Discovery Challenge financial dataset (Berka and Sochorova, 1999), available from the CTU Prague Relational Dataset Repository and mirrored on Kaggle. `sql/02_load_raw.sql` checks the row counts against the published figures, so a different version of the files will stop the build.

The files are not committed to git.
