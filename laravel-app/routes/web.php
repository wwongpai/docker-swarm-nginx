<?php

use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\Route;

Route::get('/', function () {
    Log::info('laravel-nginx-demo root hit');
    return 'laravel-nginx-demo ok';
});

Route::get('/work', function () {
    Log::info('laravel-nginx-demo work hit');
    usleep(100000); // 100 ms simulated latency
    return 'laravel-nginx-demo work done';
});
