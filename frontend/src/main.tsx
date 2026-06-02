import React from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import "./styles.css";

const root_element  =  document.getElementById( "root" );
if(  root_element === null  )  throw new Error( "Missing root element." );

createRoot( root_element ).render(
    <React.StrictMode>
        <App />
    </React.StrictMode>
);
