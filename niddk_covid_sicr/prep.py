from datetime import datetime, timedelta
import calendar
import numpy as np
import math
from numpy.random import gamma, exponential, lognormal,normal
import pandas as pd
from pathlib import Path
import sys
from os import mkdir

import niddk_covid_sicr as ncs

def get_stan_data(full_data_path, args):
    df = pd.read_csv(full_data_path)
    if getattr(args, 'last_date', None):
        try:
            datetime.strptime(args.last_date, '%m/%d/%y')
        except ValueError:
            msg = "Incorrect --last-date format, should be MM/DD/YY"
            raise ValueError(msg)
        else:
            df = df[df['dates2'] <= args.last_date]

    # t0 := where to start time series, index space
    try:
        t0 = np.where(df["new_cases"].values >= 5)[0][0]
    except IndexError:
        return [None, None]
    # tm := start of mitigation, index space

    try:
        dfm = pd.read_csv(args.data_path / 'mitigationprior.csv')
        tmdate = dfm.loc[dfm.region == args.roi, 'date'].values[0]
        tm = np.where(df["dates2"] == tmdate)[0][0]
    except Exception:
        print("Could not use mitigation prior data; setting mitigation prior to default.")
        tm = t0 + 10

    n_proj = 120
    stan_data = {}
    stan_data['n_ostates'] = 3
    stan_data['tm'] = tm
    stan_data['ts'] = np.arange(t0, len(df['dates2']) + n_proj)
    stan_data['y'] = df[['new_cases', 'new_recover', 'new_deaths']].to_numpy()\
        .astype(int)[t0:, :]
    stan_data['n_obs'] = len(df['dates2']) - t0
    stan_data['n_weeks'] = math.floor((len(df['dates2']) - t0)/7)
    stan_data['n_total'] = len(df['dates2']) - t0 + n_proj
    if args.fixed_t:
        global_start = datetime.strptime('01/22/20', '%m/%d/%y')
        frame_start = datetime.strptime(df['dates2'][0], '%m/%d/%y')
        offset = (frame_start - global_start).days
        stan_data['tm'] += offset
        stan_data['ts'] += offset
    return stan_data, df['dates2'][t0]

def get_stan_data_weekly_total(full_data_path, args):
    """ Get weekly totals for new cases, recoveries,
        and deaths from timeseries data.
    """
    df1 = pd.read_csv(full_data_path)
    if getattr(args, 'last_date', None):
        try:
            datetime.strptime(args.last_date, '%m/%d/%y')
        except ValueError:
            msg = "Incorrect --last-date format, should be MM/DD/YY"
            raise ValueError(msg)
        else:
            df1 = df1[df1['dates2'] <= args.last_date]

    n_proj = 120
    stan_data = {}

    # calculate t0 and start weekly totals on this day
    t0 = np.where(df1["new_cases"].values >= 5)[0][0] # returns index position
    df = df1.loc[t0:] # only use rows beyond and including t0

    df['Date'] = pd.to_datetime(df.loc[:, 'dates2']) # used to calculate leading week
    df.set_index('Date', inplace=True) # need this for df.resample()

    start_day = df.index[0]
    start_day = start_day.strftime("%A")
    start_abr = start_day.upper()[:3] # get 3 letter abbrev

    df['weeklytotal_new_cases'] = df.new_cases.resample('W-{}'.format(start_abr)).sum()
    df['weeklytotal_new_recover'] = df.new_recover.resample('W-{}'.format(start_abr)).sum()
    df['weeklytotal_new_deaths'] = df.new_deaths.resample('W-{}'.format(start_abr)).sum()
    df.dropna(inplace=True) # drop last rows if they spill over weekly chunks and present NAs
        # will also remove non-weekly dates so each element is by weekly amount

    df.weeklytotal_new_cases = df.weeklytotal_new_cases.astype(int) # convert float to int
    df.weeklytotal_new_recover = df.weeklytotal_new_recover.astype(int)
    df.weeklytotal_new_deaths = df.weeklytotal_new_deaths.astype(int)

    # handle negatives by setting to 0
    df['weeklytotal_new_cases'] = df['weeklytotal_new_cases'].clip(lower=0)
    df['weeklytotal_new_recover'] = df['weeklytotal_new_recover'].clip(lower=0)
    df['weeklytotal_new_deaths'] = df['weeklytotal_new_deaths'].clip(lower=0)
    df.reset_index(inplace=True) # reset index

    # tm := start of mitigation, index space
    try:
        dfm = pd.read_csv(args.data_path / 'mitigationprior.csv')
        tmdate = dfm.loc[dfm.region == args.roi, 'date'].values[0]
        tm = np.where(df["dates2"] == tmdate)[0][0]
    except Exception:
        print("Could not use mitigation prior data; setting mitigation prior to default.")
        tm = t0 + 10

    try: # Get population estimate for roi
        population = df['population'].iloc[0]
    except:
        # stan_data['N'] = 1 # If no population found in population_estimates.csv
        print("Could not get population estimate for {}".format(args.roi))

    if population:
        stan_data['N'] = population

    stan_data['n_ostates'] = 3
    stan_data['tm'] = tm
    stan_data['ts'] = np.arange(t0, len(df['dates2']) + n_proj)
    stan_data['y'] = df[['weeklytotal_new_cases', 'weeklytotal_new_recover',
                    'weeklytotal_new_deaths']].to_numpy().astype(int)[t0:, :]
    stan_data['n_obs'] = len(df['dates2']) - t0
    stan_data['n_weeks'] = len(df['dates2']) - t0
    stan_data['n_total'] = len(df['dates2']) - t0 + n_proj
    if args.fixed_t:
        global_start = datetime.strptime('01/22/20', '%m/%d/%y')
        frame_start = datetime.strptime(df['dates2'][0], '%m/%d/%y')
        offset = math.floor((frame_start - global_start).days/7)
        stan_data['tm'] += offset
        stan_data['ts'] += offset
    return stan_data, df['dates2'][t0]

def get_n_data(stan_data):
    if stan_data:
        return (stan_data['y'] > 0).ravel().sum()
    else:
        return 0


# functions used to initialize parameters
def get_init_fun(args, stan_data, force_fresh=False):
    if args.init and not force_fresh:
        try:
            init_path = Path(args.fits_path) / args.init
            model_path = Path(args.models_path) / args.model_name
            result = ncs.last_sample_as_dict(init_path, model_path)
        except Exception:
            print("Couldn't use last sample from previous fit to initialize")
            return init_fun(force_fresh=True)
        else:
            print("Using last sample from previous fit to initialize")
    else:
        print("Using default values to initialize fit")
        result = {'f1': gamma(2., 10.),
                  'f2': gamma(40., 1/100.),
                  'sigmar': gamma(20, 1/120.),
                  'sigmad': gamma(20, 1/120),
                  'sigmau': gamma(2., 1/20.),
                  'q': exponential(.1),
                  'mbase': gamma(2., .1/2.),
                  # 'mlocation': lognormal(np.log(stan_data['tm']), 1.),
                  'mlocation': normal(stan_data['tm'], 4.),
                  'extra_std': exponential(.5),
                  'extra_std_R': exponential(.5),
                  'extra_std_D': exponential(.5),
                  'cbase': gamma(1., 1.),
                  # 'clocation': lognormal(np.log(20.), 1.),
                  'clocation': normal(50., 1.),
                  'ctransition': normal(10., 1.),
                  # 'n_pop': lognormal(np.log(1e5), 1.),
                  'n_pop': normal(1e6, 1e4),
                  'sigmar1': gamma(2., .01),
                  'sigmad1': gamma(2., .01),
                  'trelax': normal(50.,5.)
                  }

    def init_fun():
        return result
    return init_fun
