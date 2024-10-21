import React from 'react';
import { Controller, useForm } from "react-hook-form";
import './App.css';
import {
  Box,
  TextField,
  Button,
  Typography,
  InputAdornment,
  IconButton,
  ToggleButton,
  ToggleButtonGroup
} from '@mui/material'
import VisibilityIcon from '@mui/icons-material/Visibility';
import VisibilityOffIcon from '@mui/icons-material/VisibilityOff';
import CircularProgress from '@mui/material/CircularProgress';
import { ToastContainer, toast, Bounce } from 'react-toastify';
import { useTranslation } from "react-i18next";
import LanguageIcon from '@mui/icons-material/Language';
import i18n from "i18next";
import 'react-toastify/dist/ReactToastify.css';

function App() {
  const queryParameters = new URLSearchParams(window.location.search)
  const uid = queryParameters.get("uid")
  const secret = queryParameters.get("secret")
  const { t } = useTranslation();
  const [isRevealPassword, setIsRevealPassword] = React.useState(false);
  const [isDownloading, setIsDownloading] = React.useState(false);
  const [language, setLanguage] = React.useState('ja');

  React.useEffect(() => {
    i18n.changeLanguage(language)
  }, [language])

  function download(blob, filename) {
    const url = window.URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.style.display = 'none';
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    window.URL.revokeObjectURL(url);
  }

  const togglePassword = () => {
    setIsRevealPassword((prevState) => !prevState);
  }
  const PasswordToggleButton = () => (
    <IconButton
      onClick={togglePassword}
      children={isRevealPassword ? <VisibilityIcon /> : <VisibilityOffIcon />}
    />
  )
  const LanguageToggleButtons = (props) => {
    const handleChange = (
      event,
      lang,
    ) => {
      setLanguage(lang);
    };


    return (
      <Box {...props}>
        <LanguageIcon sx={{ mt: 1, mr: 1 }} fontSize="large" color="action"/>
        <ToggleButtonGroup
          value={language}
          exclusive
          onChange={handleChange}
        >
          <ToggleButton value="ja">
            {t("caweb.japanese")}
          </ToggleButton>
          <ToggleButton value="en">
            {t("caweb.english")}
          </ToggleButton>
        </ToggleButtonGroup >
      </Box>
    );
  }
  const {
    handleSubmit,
    control,
  } = useForm({
    mode: "onBlur",
    criteriaMode: "all",
    shouldFocusError: false,
  });

  const onSubmit = async (data) => {
    setIsDownloading(true)
    const res = await fetch('/api/cert/pkcs12', {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify(data)
    });
    if (res.status === 200) {
      setIsDownloading(false)
      const blob = await res.blob()
      download(blob, data.uid + ".p12")
      toast.success(t("caweb.success"), {
        position: "bottom-left",
        autoClose: 5000,
        hideProgressBar: true,
        closeOnClick: true,
        pauseOnHover: true,
        draggable: true,
        progress: undefined,
        theme: "light",
        transition: Bounce,
      })
    }
    else {
      setIsDownloading(false)
      toast.error(await res.text(), {
        position: "bottom-left",
        autoClose: 5000,
        hideProgressBar: true,
        closeOnClick: true,
        pauseOnHover: true,
        draggable: true,
        progress: undefined,
        theme: "light",
        transition: Bounce,
      });
    }
  };

  return (
    <Box
      component="form"
      sx={{
        width: 1,
        height: '100vh',
        backgroundColor: "#efefef",
        display: "flex",
        flexDirection: "column",
        justifyContent: "center",
      }}
      onSubmit={handleSubmit(onSubmit)}
    >
      <ToastContainer />
      <Box sx={{
        p: 3,
        m: 2,
        borderRadius: 2,
        backgroundColor: "#ffffff",
        display: "flex",
        flexDirection: "column",
      }}>
        <Typography variant="h5" sx={{ width: 1,ml:2 }}>
          {t("caweb.title")}
        </Typography>
        <Box sx={{ width: 1, diplay: "flex-inline" }}>
          <Controller
            name="uid"
            control={control}
            rules={{
              required: t("caweb.required")
            }}
            render={({
              field: { onChange, onBlur, value },
              fieldState: { error },
            }) => (
              <TextField
                label={t("caweb.uid")}
                required
                value={value}
                defaultValue={uid}
                sx={{
                  width: "45%",
                }}
                variant="outlined"
                margin="dense"
                onChange={onChange}
                onBlur={onBlur}
                error={Boolean(error)}
                helperText={error?.message}
              />
            )}
          />
          <Controller
            name="secret"
            control={control}
            rules={{
              required: t("caweb.required")
            }}
            render={({
              field: { onChange, onBlur, value },
              fieldState: { error },
            }) => (
              <TextField
                label={t("caweb.secret")}
                required
                value={value}
                defaultValue={secret}
                sx={{
                  width: "45%",
                  ml: 2
                }}
                variant="outlined"
                margin="dense"
                onChange={onChange}
                onBlur={onBlur}
                error={Boolean(error)}
                helperText={error?.message}
              />
            )}
          />
        </Box>
        <Controller
          name="password"
          control={control}
          rules={{
            required: t("caweb.required")
          }}
          render={({
            field: { onChange, onBlur, value },
            fieldState: { error },
          }) => (
            <TextField
              label={t("caweb.password")}
              required
              value={value}
              variant="outlined"
              margin="dense"
              onChange={onChange}
              onBlur={onBlur}
              error={Boolean(error)}
              helperText={error?.message}
              type={isRevealPassword ? 'text' : 'password'}
              InputProps={{
                endAdornment: (
                  <InputAdornment position="end">
                    <PasswordToggleButton />
                  </InputAdornment>
                )
              }}
            />
          )}
        />
        <Button
          startIcon={isDownloading && <CircularProgress size={20} color="inherit" />}
          sx={{ mt: 2 }}
          type="submit"
          disabled={isDownloading}
          color="primary"
          variant="contained"
          size="large"
        >
          {t("caweb.download")}
        </Button>
      </Box>
      <LanguageToggleButtons sx={{ mr: 2, justifyContent: "flex-end", display: "inline-flex" }} />
    </Box>
  );
}

export default App;
