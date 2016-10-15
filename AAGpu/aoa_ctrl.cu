#include "aoa_ctrl.cuh"

__device__ __host__ void aoa_ctrl::update_pars(pitch_model *mdl)
{
    if (already_preupdated)
    {
        already_preupdated = false;
        return;
    }
    cur_aoa_equilibr = aoa_ctrl::get_equlibr(mdl, mdl->aoa)(0, 0);
}

__device__ __host__ matrix<2, 1> aoa_ctrl::get_equlibr(pitch_model *mdl, float aoa)
{
    matrix<2, 2> eq_A;
    matrix<2, 1> eq_B;
    eq_A(0, 0) = mdl->A(0, 1);
    eq_A(0, 1) = mdl->A(0, 2) + mdl->B(0, 0);
    eq_A(1, 0) = mdl->A(1, 1);
    eq_A(1, 1) = mdl->A(1, 2) + mdl->B(1, 0);
    eq_B(0, 0) = -(mdl->A(0, 0) * aoa + mdl->C(0, 0));
    eq_B(1, 0) = -(mdl->A(1, 0) * aoa + mdl->C(1, 0));
    matrix<2, 1> eq_x = eq_A / eq_B;
    return eq_x;
}

__device__ __host__ static float predict_aoa(pitch_model *mdl, float ctrl, float dt)
{
    float csurf;
    if (aero_model)
        csurf = mdl->csurf_state;
    else
        csurf = moveto(mdl->csurf_state, ctrl, dt * stock_csurf_spd);
    float pred_aoa = (float)(mdl->A.rowSlice<0>() * colVec(mdl->aoa, mdl->ang_vel, csurf)) +
        mdl->B(0, 0) * ctrl + mdl->C(0, 0);
    return mdl->aoa + pred_aoa * dt;
}

# define AOAPCITER 1

__device__ __host__ float aoa_ctrl::eval(pitch_model *mdl, ang_vel_p *vel_c, 
    float target, float target_deriv, float dt)
{
    vel_c->preupdatev(mdl);
    update_pars(mdl);    
    target_aoa = clamp(target, vel_c->res_min_aoa, vel_c->res_max_aoa);    

    float cur_aoa = mdl->aoa;
    float prev_out_vel = output_vel;
    float output_shift = get_output(vel_c, cur_aoa, target, dt);
    float des_aoa_equil = get_equlibr(mdl, target)(0, 0);
    float aoa_err = target_aoa - cur_aoa;
    output_vel = output_shift + des_aoa_equil;
    float shift_ang_vel = mdl->ang_vel - cur_aoa_equilibr;
    predicted_aoa = cur_aoa + shift_ang_vel * dt;
    if (aoa_err * (target_aoa - predicted_aoa) < 0.0f)
        predicted_aoa = target_aoa;
    predicted_output = get_output(vel_c, predicted_aoa, target_aoa, dt);
    //predicted_eq_v = get_equlibr(mdl, predicted_aoa)(0, 0);
    //float cur_deriv = (output_vel - prev_out_vel) / dt;
    float pred_deriv = (predicted_output - output_shift) / dt;
    output_acc = pred_deriv;

    /*if (aoa_err * output_acc > 0.0f)
    {
        output_acc = 0.0f;
        return vel_c->eval(mdl, output_vel, output_acc, dt);
    }*/

    for (int i = 0; i < AOAPCITER; i++)
    {
        float cout = vel_c->eval(mdl, output_vel, output_acc, dt);
        vel_c->already_preupdated = true;

        // now let's reiterate derivative calculation
        predicted_aoa = predict_aoa(mdl, cout, dt);

        //if (aoa_err * (target_aoa - predicted_aoa) < 0.0f)
        //    predicted_aoa = target_aoa;
        predicted_output = get_output(vel_c, predicted_aoa, target_aoa, dt);
        //predicted_eq_v = get_equlibr(mdl, predicted_aoa)(0, 0);
        pred_deriv = (predicted_output - output_shift) / dt;
        output_acc = pred_deriv;
    }

    return vel_c->eval(mdl, output_vel, output_acc, dt);
}

__device__ __host__ void aoa_ctrl::preupdate(pitch_model *mdl)
{
    update_pars(mdl);
    already_preupdated = true;
}

__device__ __host__ float aoa_ctrl::get_output(ang_vel_p *vel_c, float cur_aoa, 
    float des_aoa, float dt)
{
    float error = des_aoa - cur_aoa;
    float k = params(0, 0);
    float p = params(1, 0);
    float x = powf(fabsf(error) / k, 1.0f / p);
    if (x <= dt)
        return error / dt;
    else
        return -copysignf(1.0f, error) * k * (powf(x - dt, p) - powf(x, p)) / dt;
}