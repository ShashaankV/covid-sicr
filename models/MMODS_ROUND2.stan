// MMODSRound2.stan
// Latent variable nonlinear SICR model with mitigation from mobile data, q>0, and fixed population

functions {
         // time transition functions for beta and sigmac
         // day 0 = 3/20/2020
         // mobility data starts on 2/15/2020 = day 34
         // shift mobility by 34 days
         // May 15 = day 56
         // Nov 15 = day 56 + 184

         //
         real mitigation(real base,real t) {
                 real scale;
                 if (t < 56.){
                    scale = base + (1 - base) / (1 + exp(0.47 * (t + 2))/(1 + exp(.52*(t - 8.))));
                    //scale = 0.55 + (1 - 0.55) / (1 + exp(0.47 * (t - 32))/(1 + exp(.52*(t-42.))));
                    }
                 else {
                    scale = base + (1 - base) /10.974;
                 }
                 return scale;
         }

         // Relaxation function
         real relax(real base, real t) {
              real scale;
              scale = base + (1 - base) /10.974;
              return scale*(1 + 0.42924175/(1 + exp(-0.2154182*(t - 20.29067964))));
         }

         // nonlinear SICR model ODE function
           real[] SICR(
           real t,             // time
           real[] u,           // system state {infected,cases,susceptible}
           real[] theta,       // parameters
           real[] x_r,
           int[] x_i
           )
           {
             real du_dt[5];
             real f1 = theta[1];          // beta - sigmau - sigmac
             real f2 = theta[2];          // beta - sigma u
             real sigmar = theta[3];
             real sigmad =  theta[4];
             real sigmau = theta[5];
             real q = theta[6];
             real mbase = theta[7];
             real trelax = theta[8];

             real sigma = sigmar + sigmad;
             real sigmac = f2/(1+f1);
             real beta = f2 + sigmau;

             real I = u[1];  // infected, latent
             real C = u[2];  // cases, observed
             real Z = u[3];  // total infected

             //sigmac *= transition(cbase,clocation,t);  // case detection change
             if (t < trelax) {
                beta *= mitigation(mbase,t);  // mitigation
             }
             else {
                beta *= relax(mbase,t-trelax);   // relaxation from lockdown
             }


             du_dt[1] = beta*(I+q*C)*(1-Z) - sigmac*I - sigmau*I; // I
             du_dt[2] = sigmac*I - sigma*C;                       // C
             du_dt[3] = beta*(I+q*C)*(1-Z);                       // Z = N_I cumulative infected
             du_dt[4] = sigmac*I;                                 // N_C cumulative cases
             du_dt[5] = C;                                        // integrated C

             return du_dt;
            }
       }

data {
  int<lower=1> n_obs;       // number of days observed
  int<lower=1> n_total;      // total number of days until Nov 15
  int<lower=1> n_ostates;   // number of observed states
  int y[n_obs,n_ostates];     // data, per-day-tally [cases,recovered,death]
  real ts[n_total];             // time points for ode solver
  }

transformed data {
    real x_r[0];
    int x_i[0];
    int n_difeq = 5;     // number of differential equations for yhat
    real n_pop = 100000;
}

parameters {
    real<lower=0> f1;             // initial infected to case ratio
    real<lower=0> f2;             // f2  beta - sigmau
    real<lower=0> sigmar;         // recovery rate
    real<lower=0> sigmad;         // death rate
    real<lower=0> sigmau;         // I disappearance rate
    real<lower=0> mbase;          // mitigation strength
    real<lower=0> extra_std;      // phi = 1/extra_std^2 in neg_binomial_2(mu,phi)
    real<lower=0> q;              // infection factor for cases

}

transformed parameters{
  real<lower=0.> lambda[n_total,3]; //mean rate [new cases, new recovered, new deaths]
  real car[n_obs];      //total cases / total infected
  real ifr[n_obs];      //total dead / total infected
  //real Rt[n_obs];           // time dependent reproduction number
  real u_init[5];     // initial conditions for fractions

  real sigmac = f2/(1+f1);
  real beta = f2 + sigmau;
  real sigma = sigmar + sigmad;
  real R0 = beta*(sigma+q*sigmac)/sigma/(sigmac+sigmau);   // reproduction number
  real phi = max([1/(extra_std^2),1e-10]); // likelihood over-dispersion of std

  {
     real theta[8] = {f1, f2, sigmar, sigmad, sigmau, q, mbase, 243.};
     real u[n_total, 5];   // solution from the ODE solver
     real betat;


     real cinit = y[1,1]/n_pop;

     u_init[1] = f1*cinit;      // I set from f1 * C initial
     u_init[2] = cinit;         //C  from data
     u_init[3] = u_init[1];     // N_I cumulative infected
     u_init[4] = cinit;         // N_C total cumulative cases
     u_init[5] = cinit;         // integral of active C

     u = integrate_ode_rk45(SICR, u_init, ts[1]-1, ts, theta, x_r, x_i,1e-3,1e-5,10000);

     for (i in 1:n_obs){
        car[i] = u[i,4]/u[i,3];
        ifr[i] = sigmad*u[i,5]/u[i,3];
        betat = beta*mitigation(mbase,i)*(1-u[i,3]);
        //Rt[i] = betat*(sigma+q*sigmac)/sigma/(sigmac+sigmau);
        }

     lambda[1,1] = max([(u[1,4]-u_init[4])*n_pop,0.01]);         // new cases per day
     lambda[1,2] = max([sigmar*(u[1,5]-u_init[5])*n_pop,0.01]); // new recovered per day
     lambda[1,3] = max([sigmad*(u[1,5]-u_init[5])*n_pop,0.01]);  // new deaths per day
     //lambda[1,4] = max([(u[1,3]-u_init[3])*n_pop,0.01]);  // new infected per day
     //lambda[1,5] = max([u[1,2]*n_pop,0.01]); // mean active cases

     for (i in 2:n_total){
        lambda[i,1] = max([(u[i,4]-u[i-1,4])*n_pop,0.01]);         // new cases per day
        lambda[i,2] = max([sigmar*(u[i,5]-u[i-1,5])*n_pop,0.01]);  // new recovered rate per day
        lambda[i,3] = max([sigmad*(u[i,5]-u[i-1,5])*n_pop,0.01]);  // new deaths per day
      //  lambda[i,4] = max([(u[i,3]-u[i-1,3])*n_pop,0.01]);         // new infected per day
      //  lambda[i,5] = max([u[i,2]*n_pop,0.01]);    // mean active cases
        }
    }
}


model {
    //priors Stan convention:  gamma(shape,rate), inversegamma(shape,rate)

    // fit10: US_NY posteriors
    f1 ~ gamma(2.4,.1);                 // f1  initial infected to case ratio
    f2 ~ gamma(175.,420.);              // f2
    sigmar ~ gamma(16.,120.);           // sigmar
    sigmad ~ gamma(19.,1200.);          // sigmad
    sigmau ~ gamma(2.,23.);             // sigmau
    q ~ gamma(.9,2.3);                  // q
    mbase ~ gamma(10.,30.);             // mbase
    extra_std ~ gamma(394.,656.);       // likelihood over dispersion std

/*
    //fit10: US_MD posteriors
    f1 ~ gamma(1.7,.1);                 // f1  initial infected to case ratio
    f2 ~ gamma(99.,341.);              // f2
    sigmar ~ gamma(41.,3600.);           // sigmar
    sigmad ~ gamma(56.,8600.);          // sigmad
    sigmau ~ gamma(2.,20.);             // sigmau
    q ~ gamma(1.1,2.);                  // q
    mbase ~ gamma(9.,30.);             // mbase
    extra_std ~ gamma(300.,400.);       // likelihood over dispersion std
*/

    //likelihood
    for (i in 1:n_obs){
        target += neg_binomial_2_lpmf(y[i,1]|lambda[i,1],phi);
        target += neg_binomial_2_lpmf(y[i,2]|lambda[i,3],phi);
        target += exponential_lpdf(ifr[i] | 10.);   // regularization
        target += gamma_lpdf(car[i] | 2.,10.);
    }
}

generated quantities {

int<lower=0> cum_deaths[185,4];
int<lower=0> cum_infected[185,4];
int<lower=0> active_cases[185,4];
int<lower=0> new_cases[185,4];
real max_hospitalization[4];

int moving_sum[186];
real<lower=0> t2wks;
real<lower=0> t5pc;
real<lower=0> prob_outbreak[4];
real fhosp;

real llx[n_obs, 2];
real ll_; // log-likelihood for model

fhosp = gamma_rng(1.68, 0.273)/100.;

ll_ = 0;
for (i in 1:n_obs) {
            llx[i, 1] = neg_binomial_2_lpmf(y[i,1]|lambda[i,1],phi);
            llx[i, 2] = neg_binomial_2_lpmf(y[i,2]|lambda[i,3],phi);
            ll_ += llx[i,1];
            ll_ += llx[i,2];
    }

  {
    real hospitalization[4,185];
    int cases[186+7];

    int delta_mov_sum[185];
    int ndays;
    int ndecreasing;
    int nzeros;
    int peak;
    int flag2wks;
    int flag5pc;

    real u[n_total, 5];
    real mean_new_cases[185,4];
    real trelax[4];
    real theta[8] ;
    theta = {f1, f2, sigmar, sigmad, sigmau, q, mbase, 243.};

    u = integrate_ode_rk45(SICR, u_init, ts[1]-1, ts, theta, x_r, x_i,1e-3,1e-5,10000);

    // load cases 7 days before May 15
    moving_sum[1] = 0;
    for (i in 1:7) {
        cases[i] = y[n_obs-8+i,1];
        moving_sum[1] += cases[i];  // moving sum on May 14
    }

    active_cases[1,1] = neg_binomial_2_rng(max([u[n_obs,2]*n_pop,0.0001]),phi);
    cum_deaths[1,1]   =   neg_binomial_2_rng(max([sigmad*(u[n_obs,5]-u[n_obs-1,5])*n_pop,0.0001]),phi);
    cum_infected[1,1] = neg_binomial_2_rng(max([(u[n_obs,3]-u[n_obs-1,3])*n_pop,0.0001]),phi);
    mean_new_cases[1,1] = max([(u[n_obs,4]-u[n_obs-1,4])*n_pop,0.0001]);
    new_cases[1,1]    = neg_binomial_2_rng(mean_new_cases[1,1],phi);
    hospitalization[1,1] = fhosp * active_cases[1,1];

    cases[8] = new_cases[1,1];
    moving_sum[2] = cases[8] + moving_sum[1] - cases[1];   // moving avg on May 15

    // project cases forward from May 15 to Nov 15 inclusive
    for (i in 2:185) {
        active_cases[i,1] = neg_binomial_2_rng(max([u[n_obs+i-1,2]*n_pop,0.0001]),phi);
        cum_deaths[i,1] =   cum_deaths[i-1,1] + neg_binomial_2_rng(max([sigmad*(u[n_obs+i-1,5]-u[n_obs+i-2,5])*n_pop,0.0001]),phi);
        cum_infected[i,1] = cum_infected[i-1,1] + neg_binomial_2_rng(max([(u[n_obs+i-1,3]-u[n_obs+i-2,3])*n_pop,0.0001]),phi);
        mean_new_cases[i,1] = max([(u[n_obs+i-1,4]-u[n_obs+i-2,4])*n_pop,0.0001]);
        new_cases[i,1] = neg_binomial_2_rng(mean_new_cases[i,1],phi);
        hospitalization[1,i] = fhosp * active_cases[i,1];

        cases[7+i] = new_cases[i,1];
        moving_sum[i+1] = cases[i+7] + moving_sum[i] - cases[i];
     }

  for (i in 1:185){
    if (moving_sum[i+1]-moving_sum[i] < 0) {
        delta_mov_sum[i] = 1;    // days when moving sum dropped
    }
    else {
        delta_mov_sum[i] = 0;
    }
 }

 //print(moving_sum);
 //print(delta_mov_sum);

// find the peak in the 7-day moving average
  peak = moving_sum[1];
  ndays = 0;
  nzeros = 0;
  ndecreasing = 0;
  flag2wks = 0;
  flag5pc = 0;
  t5pc = 185;
  t2wks = 185;
  for (i in 1:185) {
    if (moving_sum[i+1] > peak){
        peak = moving_sum[i+1];  // set new peak
        ndays = 0;
        ndecreasing = 0;
        nzeros = 0;
        //print(i);
        }
    else {
      ndays += 1;   // count days since peak
      ndecreasing += delta_mov_sum[i];   // count number of decreasing days since peak
      if (moving_sum[i+1] == 0)  {  // nzero cases for past 7 days
         nzeros += 1;        // count zero case days since last peak
      }
      if (ndays > 13 && flag2wks == 0) // at least 2 weeks after peak
        if (ndecreasing > 9|| nzeros > 6) {  // 10 decreasing days or 7 zero days
          t2wks = i;
          flag2wks = 1;      // set flag for date obtained
          //print(t2wks," ",ndays," ",ndecreasing," ",nzeros);
        }

      if (moving_sum[i+1] < .05*peak && flag5pc == 0) {
        t5pc = i;
        flag5pc = 1;       // set flag for date obtained
        }
      }
}

    trelax = {185,t2wks,t5pc,0};

    for (j in 2:4) {

        theta[8] = trelax[j] + 56;

        u = integrate_ode_rk45(SICR, u_init, ts[1]-1, ts, theta, x_r, x_i,1e-3,1e-5,10000);

        active_cases[1,j] = neg_binomial_2_rng(max([u[n_obs,2]*n_pop,0.0001]),phi);
        cum_deaths[1,j] =   neg_binomial_2_rng(max([sigmad*(u[n_obs,5]-u[n_obs-1,5])*n_pop,0.0001]),phi);
        cum_infected[1,j] = neg_binomial_2_rng(max([(u[n_obs,3]-u[n_obs-1,3])*n_pop,0.0001]),phi);
        mean_new_cases[1,j] = max([(u[n_obs,4]-u[n_obs-1,4])*n_pop,0.0001]);
        new_cases[1,j] = neg_binomial_2_rng(mean_new_cases[1,j],phi);
        hospitalization[j,1] = fhosp * active_cases[1,j];

        for (i in 2:185) {
            active_cases[i,j] = neg_binomial_2_rng(max([u[n_obs+i-1,2]*n_pop,0.0001]),phi);
            cum_deaths[i,j] =   cum_deaths[i-1,j] + neg_binomial_2_rng(max([sigmad*(u[n_obs+i-1,5]-u[n_obs+i-2,5])*n_pop,0.0001]),phi);
            cum_infected[i,j] = cum_infected[i-1,j] + neg_binomial_2_rng(max([(u[n_obs+i-1,3]-u[n_obs+i-2,3])*n_pop,0.0001]),phi);
            mean_new_cases[i,j] = max([(u[n_obs+i-1,4]-u[n_obs+i-2,4])*n_pop,0.0001]);
            new_cases[i,j] = neg_binomial_2_rng(mean_new_cases[i,j],phi);
            hospitalization[j,i] = fhosp * active_cases[i,j];
        }
    }

    for (j in 1:4) {
      max_hospitalization[j] = max(hospitalization[j]);
      prob_outbreak[j] = 0;
      for (k in 1:1000)
        for (i in 1:185)
           if (neg_binomial_2_rng(mean_new_cases[i,j],phi) > 10) {
             prob_outbreak[j] += 1;
             break;
           }
      prob_outbreak[j] /= 1000.;
    }

  }

}
